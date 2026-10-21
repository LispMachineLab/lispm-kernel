;;;; runtime.lisp --- Requests, worker pools and the outbox

;; Copyright (C) 2026  Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU Affero General Public License as published
;; by the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU Affero General Public License for more details.

;; You should have received a copy of the GNU Affero General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Emacs asks for a job by name, with a request ID of its choosing, an
;;; owner, a generation and a priority:
;;;
;;;   Emacs  (submit 7 scan-sessions (:agent codex :root "...") :owner 1 :generation 3)
;;;   kernel (chunk 7 DATA) ...  then exactly one  (done 7 STATUS VALUE)
;;;
;;; STATUS is success, failed (VALUE says why), cancelled, or rejected
;;; (VALUE says why: capacity, stale, unknown-job, duplicate, closed).
;;; Every request Emacs sends gets its one done, and its chunks come
;;; before it.
;;;
;;; Requests wait in a queue per class of work, :cpu or :io, each served
;;; by threads of its own.  A worker takes the request of the highest
;;; priority, one more for each `*aging-milliseconds*' it has waited, the
;;; oldest of equals first.  An owner's newer generation cancels its older
;;; requests, and a request of an older one is rejected as stale.
;;; Cancelling a queued request answers it at once; a running one stops
;;; at its next `checkpoint'.
;;;
;;; Messages for Emacs wait in the outbox, which one thread writes out.
;;; Chunks count against `*outbox-limit*': while Emacs reads slower than
;;; jobs emit, a job emitting waits, until there is room or it is
;;; cancelled.  Final and other messages never wait.

(in-package #:lispm-kernel)

(defconstant +protocol+ 1
  "The protocol the kernel speaks; Emacs refuses a kernel of another.")

(defparameter *max-requests* 256
  "Requests accepted and not yet answered, at most.")

(defparameter *max-requests-per-owner* 64
  "Requests of one owner accepted and not yet answered, at most.")

(defparameter *outbox-limit* (* 4 1024 1024)
  "Characters of chunks waiting for Emacs, at most, but for one chunk alone.")

(defparameter *max-final-length* (* 4 1024 1024)
  "Characters of one final message, at most: a longer result fails.")

(defparameter *aging-milliseconds* 50
  "How long a queued request waits for its priority to rise by one.")

(defparameter *max-error-length* 2000
  "Characters of the reason a failure gives, at most.")

(defvar *cache-clearers* '()
  "Functions that free what jobs keep between requests, called when Emacs
sends (clear-caches).")

;;;; Jobs

(defstruct (job (:constructor make-job (name class function)) (:copier nil))
  (name nil :type keyword :read-only t)
  (class :cpu :type (member :cpu :io) :read-only t)
  (function #'identity :type function :read-only t))

(defvar *jobs* (make-hash-table :test 'eq)
  "The jobs Emacs may ask for, by name.")

(defmacro define-job ((name &key (class :cpu)) (input) &body body)
  "Define the job NAME, which Emacs asks for as (submit ID NAME INPUT ...).
BODY runs on a worker of CLASS, :cpu or :io, with INPUT bound to the
datum Emacs sent, and its value is the result Emacs gets.  It may `emit'
chunks before, and calls `checkpoint' between steps, where a cancelled
request stops.  An error it signals fails the request."
  (let ((keyword (intern (string name) :keyword)))
    `(progn
       (setf (gethash ,keyword *jobs*)
             (make-job ,keyword ,class (lambda (,input)
                                         (declare (ignorable ,input))
                                         ,@body)))
       ',name)))

;;;; Requests

(defstruct (request (:constructor make-request (id job input owner generation priority))
                    (:copier nil))
  (id 0 :type (integer 0) :read-only t)
  (job nil :type job :read-only t)
  (input nil :read-only t)
  (owner 0 :type integer :read-only t)
  (generation 0 :type integer :read-only t)
  (priority 0 :type integer :read-only t)
  (submitted (get-internal-real-time) :type integer :read-only t)
  (state :queued :type (member :queued :running :answered))
  (cancelled nil))

(defvar *request* nil
  "The request this thread works on, or nil.")

(defun checkpoint ()
  "Stop the current request here when it was cancelled.
Outside a request it does nothing."
  (let ((request *request*))
    (when (and request (request-cancelled request))
      (throw 'cancelled nil))))

;;;; The outbox

(defstruct (outbox (:constructor make-outbox ()) (:copier nil))
  (lock (sb-thread:make-mutex :name "outbox") :read-only t)
  (ready (sb-thread:make-waitqueue :name "outbox ready") :read-only t)
  (room (sb-thread:make-waitqueue :name "outbox room") :read-only t)
  ;; Messages in order, as (STRING . LENGTH-COUNTED-OR-NIL).
  (head '() :type list)
  (tail '() :type list)
  (waiting 0 :type (integer 0))
  (peak 0 :type (integer 0))
  (closed nil))

(defun outbox-put (outbox string &key request)
  "Queue STRING, one message, for Emacs; return true.
With REQUEST, STRING is one of its chunks: it counts against
`*outbox-limit*', and while there is no room for it this waits; when
REQUEST is cancelled meanwhile, nothing is queued and nil returned."
  (let ((length (length string)))
    (sb-thread:with-mutex ((outbox-lock outbox))
      (when request
        (loop while (and (plusp (outbox-waiting outbox))
                         (> (+ (outbox-waiting outbox) length) *outbox-limit*)
                         (not (outbox-closed outbox))
                         (not (request-cancelled request)))
              do (sb-thread:condition-wait (outbox-room outbox) (outbox-lock outbox)))
        (when (request-cancelled request)
          (return-from outbox-put nil))
        (incf (outbox-waiting outbox) length)
        (setf (outbox-peak outbox) (max (outbox-peak outbox) (outbox-waiting outbox))))
      (let ((cell (list (cons string (and request length)))))
        (if (outbox-tail outbox)
            (setf (cdr (outbox-tail outbox)) cell)
            (setf (outbox-head outbox) cell))
        (setf (outbox-tail outbox) cell))
      (sb-thread:condition-notify (outbox-ready outbox))
      t)))

(defun outbox-take (outbox)
  "Wait for messages, and return every one queued, in order.
Return nil once the outbox is closed and empty."
  (sb-thread:with-mutex ((outbox-lock outbox))
    (loop while (and (null (outbox-head outbox)) (not (outbox-closed outbox)))
          do (sb-thread:condition-wait (outbox-ready outbox) (outbox-lock outbox)))
    (let ((messages (outbox-head outbox)))
      (setf (outbox-head outbox) '()
            (outbox-tail outbox) '())
      (dolist (message messages)
        (when (cdr message)
          (decf (outbox-waiting outbox) (cdr message))))
      (sb-thread:condition-broadcast (outbox-room outbox))
      (mapcar #'car messages))))

(defun outbox-wake (outbox)
  "Wake the jobs waiting for room, so that a cancelled one stops waiting."
  (sb-thread:with-mutex ((outbox-lock outbox))
    (sb-thread:condition-broadcast (outbox-room outbox))))

(defun outbox-close (outbox)
  "Let the writer end once it has written what is queued."
  (sb-thread:with-mutex ((outbox-lock outbox))
    (setf (outbox-closed outbox) t)
    (sb-thread:condition-broadcast (outbox-ready outbox))
    (sb-thread:condition-broadcast (outbox-room outbox))))

;;;; The kernel

(defstruct (kernel (:constructor make-kernel (outbox)) (:copier nil))
  (lock (sb-thread:make-mutex :name "kernel") :read-only t)
  (cpu-work (sb-thread:make-waitqueue :name "cpu work") :read-only t)
  (io-work (sb-thread:make-waitqueue :name "io work") :read-only t)
  ;; Queued requests of each class, the oldest first.
  (cpu-queue '() :type list)
  (io-queue '() :type list)
  ;; Requests accepted and not yet answered, by ID.
  (requests (make-hash-table) :read-only t)
  ;; The current generation of each owner that has one.
  (generations (make-hash-table) :read-only t)
  ;; Requests accepted and not yet answered, by owner.
  (owner-counts (make-hash-table) :read-only t)
  (counts (make-hash-table :test 'eq) :read-only t)
  (outbox nil :type outbox :read-only t)
  (writer nil)
  (workers '() :type list)
  (started (get-internal-real-time) :read-only t)
  (closed nil))

(defvar *kernel* nil
  "The kernel this process runs for Emacs.")

(defun queue (kernel class)
  (ecase class
    (:cpu (kernel-cpu-queue kernel))
    (:io (kernel-io-queue kernel))))

(defun (setf queue) (requests kernel class)
  (ecase class
    (:cpu (setf (kernel-cpu-queue kernel) requests))
    (:io (setf (kernel-io-queue kernel) requests))))

(defun work-waitqueue (kernel class)
  (ecase class
    (:cpu (kernel-cpu-work kernel))
    (:io (kernel-io-work kernel))))

(defun tally (kernel what &optional (amount 1))
  (incf (gethash what (kernel-counts kernel) 0) amount))

(defun effective-priority (request now)
  "Return REQUEST's priority at NOW, raised by how long it has waited."
  (+ (request-priority request)
     (floor (* (- now (request-submitted request)) 1000)
            (* *aging-milliseconds* internal-time-units-per-second))))

(defun condition-text (condition)
  "Return what CONDITION says, at most `*max-error-length*' characters."
  (let ((text (handler-case (let ((*print-length* 16) (*print-level* 4) (*print-readably* nil))
                              (princ-to-string condition))
                (error () (string (type-of condition))))))
    (if (> (length text) *max-error-length*)
        (subseq text 0 *max-error-length*)
        text)))

(defun final-message (request status value)
  "Return REQUEST's final message, (done ID STATUS VALUE).
A VALUE that cannot be sent, or is too long, fails the request instead."
  (let* ((id (request-id request))
         (text (handler-case (message-string (list 'done id status value))
                 (wire-error (condition)
                   (message-string
                    (list 'done id 'failed
                          (format nil "The result cannot be sent to Emacs: ~A"
                                  (condition-text condition))))))))
    (if (> (length text) *max-final-length*)
        (message-string (list 'done id 'failed "The result is too long to send to Emacs"))
        text)))

(defun forget (kernel request)
  "Free what REQUEST holds of KERNEL's admission; the lock is held."
  (remhash (request-id request) (kernel-requests kernel))
  (let ((owner (request-owner request))
        (counts (kernel-owner-counts kernel)))
    (if (<= (gethash owner counts 0) 1)
        (remhash owner counts)
        (decf (gethash owner counts)))))

(defun answer-locked (kernel request status value)
  "Answer REQUEST with STATUS and VALUE, the lock held; return its final
message, or nil when it was answered before.  A cancelled request is
answered as cancelled, whatever it did."
  (unless (eq (request-state request) :answered)
    (when (request-cancelled request)
      (setf status 'cancelled value nil))
    (setf (request-state request) :answered)
    (forget kernel request)
    (tally kernel status)
    (final-message request status value)))

(defun answer (kernel request status value)
  "Give Emacs REQUEST's final message, unless it was answered before."
  (let ((message (sb-thread:with-mutex ((kernel-lock kernel))
                   (answer-locked kernel request status value))))
    (when message
      (outbox-put (kernel-outbox kernel) message))))

(defun cancel-locked (kernel request)
  "Cancel REQUEST, the lock held.  A queued request is answered here and its
final message returned; a running one stops at its next checkpoint."
  (setf (request-cancelled request) t)
  (when (eq (request-state request) :queued)
    (let ((class (job-class (request-job request))))
      (setf (queue kernel class) (remove request (queue kernel class))))
    (answer-locked kernel request 'cancelled nil)))

(defun supersede-locked (kernel owner generation)
  "Make GENERATION OWNER's current one, cancelling its older requests, the
lock held; return the final messages of those that were queued."
  (when (> generation (gethash owner (kernel-generations kernel) 0))
    (setf (gethash owner (kernel-generations kernel)) generation)
    (let ((older (loop for request being the hash-values of (kernel-requests kernel)
                       when (and (= (request-owner request) owner)
                                 (< (request-generation request) generation))
                         collect request)))
      (remove nil (mapcar (lambda (request) (cancel-locked kernel request)) older)))))

(defun post-all (kernel messages)
  "Queue MESSAGES for Emacs and wake jobs waiting for room."
  (let ((outbox (kernel-outbox kernel)))
    (dolist (message messages)
      (outbox-put outbox message))
    (outbox-wake outbox)))

(defun reject (kernel id reason)
  (sb-thread:with-mutex ((kernel-lock kernel))
    (tally kernel 'rejected))
  (outbox-put (kernel-outbox kernel) (message-string (list 'done id 'rejected reason))))

(defun submit (kernel id name input &key (owner 0) (generation 0) (priority 0))
  "Accept request ID for the job NAME with INPUT, or reject it."
  (let ((job (gethash name *jobs*))
        (reason nil)
        (cancelled '()))
    (sb-thread:with-mutex ((kernel-lock kernel))
      (let ((requests (kernel-requests kernel)))
        (setf reason
              (cond ((kernel-closed kernel) 'closed)
                    ((gethash id requests) 'duplicate)
                    ((null job) 'unknown-job)
                    ((< generation (gethash owner (kernel-generations kernel) 0)) 'stale)))
        (unless reason
          (setf cancelled (supersede-locked kernel owner generation))
          (setf reason
                (cond ((>= (hash-table-count requests) *max-requests*) 'capacity)
                      ((>= (gethash owner (kernel-owner-counts kernel) 0) *max-requests-per-owner*)
                       'capacity))))
        (unless reason
          (let ((request (make-request id job input owner generation priority))
                (class (job-class job)))
            (setf (gethash id requests) request)
            (incf (gethash owner (kernel-owner-counts kernel) 0))
            (setf (queue kernel class) (append (queue kernel class) (list request)))
            (tally kernel 'accepted)
            (setf (gethash 'peak-queued (kernel-counts kernel))
                  (max (gethash 'peak-queued (kernel-counts kernel) 0)
                       (+ (length (kernel-cpu-queue kernel)) (length (kernel-io-queue kernel)))))
            (sb-thread:condition-notify (work-waitqueue kernel class))))))
    (post-all kernel cancelled)
    (when reason
      (reject kernel id reason))
    (not reason)))

(defun cancel (kernel id)
  "Cancel request ID, if it is not answered yet."
  (post-all kernel (sb-thread:with-mutex ((kernel-lock kernel))
                     (let ((request (gethash id (kernel-requests kernel))))
                       (and request (remove nil (list (cancel-locked kernel request))))))))

(defun supersede (kernel owner generation)
  "Make GENERATION OWNER's current one, cancelling its older requests."
  (post-all kernel (sb-thread:with-mutex ((kernel-lock kernel))
                     (supersede-locked kernel owner generation))))

;;;; Workers

(defun take-request (kernel class)
  "Wait for a request of CLASS and return the one to run next, or nil once
the kernel is closed."
  (sb-thread:with-mutex ((kernel-lock kernel))
    (loop
      (when (kernel-closed kernel)
        (return nil))
      (let ((queue (queue kernel class)))
        (when queue
          (let* ((now (get-internal-real-time))
                 (best (first queue))
                 (best-priority (effective-priority best now)))
            (dolist (request (rest queue))
              (let ((priority (effective-priority request now)))
                (when (> priority best-priority)
                  (setf best request best-priority priority))))
            (setf (queue kernel class) (remove best queue :count 1)
                  (request-state best) :running)
            (return best))))
      (sb-thread:condition-wait (work-waitqueue kernel class) (kernel-lock kernel)))))

(defun run-request (kernel request)
  "Run REQUEST's job and answer it."
  (let* ((*kernel* kernel)
         (*request* request)
         (outcome (catch 'cancelled
                    (handler-case
                        (list 'success (funcall (job-function (request-job request))
                                                (request-input request)))
                      (serious-condition (condition)
                        (list 'failed (condition-text condition)))))))
    (if outcome
        (answer kernel request (first outcome) (second outcome))
        (answer kernel request 'cancelled nil))))

(defun worker-loop (kernel class)
  (loop for request = (take-request kernel class)
        while request
        do (handler-case (run-request kernel request)
             (serious-condition (condition)
               (format *error-output* "lispm-kernel: a worker failed: ~A~%"
                       (condition-text condition))))))

(defun write-loop (outbox sink)
  "Give SINK the messages of OUTBOX as they come, until it is closed."
  (loop for messages = (outbox-take outbox)
        while messages
        do (funcall sink messages)))

(defun start-kernel (sink &key (cpu-workers 2) (io-workers 4))
  "Start a kernel and return it.
Its messages for Emacs go to SINK, a function called with a list of them,
strings, in order, on a thread of its own.  CPU-WORKERS and IO-WORKERS
threads run the jobs of each class."
  (let* ((outbox (make-outbox))
         (kernel (make-kernel outbox)))
    (setf (kernel-writer kernel)
          (sb-thread:make-thread #'write-loop :name "lispm-kernel writer"
                                              :arguments (list outbox sink)))
    (flet ((workers (class count)
             (loop for index from 1 to count
                   collect (sb-thread:make-thread
                            #'worker-loop
                            :name (format nil "lispm-kernel ~(~A~) worker ~D" class index)
                            :arguments (list kernel class)))))
      (setf (kernel-workers kernel)
            (append (workers :cpu cpu-workers) (workers :io io-workers))))
    kernel))

(defun stop-kernel (kernel &key (timeout 10))
  "Close KERNEL: reject new requests, cancel those there are, wait for its
threads at most TIMEOUT seconds each and let its writer finish."
  (let ((cancelled (sb-thread:with-mutex ((kernel-lock kernel))
                     (setf (kernel-closed kernel) t)
                     (let ((requests (loop for request being the hash-values of (kernel-requests kernel)
                                           collect request)))
                       (prog1 (remove nil (mapcar (lambda (request) (cancel-locked kernel request))
                                                  requests))
                         (sb-thread:condition-broadcast (kernel-cpu-work kernel))
                         (sb-thread:condition-broadcast (kernel-io-work kernel)))))))
    (post-all kernel cancelled)
    (dolist (worker (kernel-workers kernel))
      (sb-thread:join-thread worker :default nil :timeout timeout))
    (outbox-close (kernel-outbox kernel))
    (sb-thread:join-thread (kernel-writer kernel) :default nil :timeout timeout)
    kernel))

(defun kernel-stats (kernel)
  "Return a plist of what KERNEL holds and has done."
  (let ((outbox (kernel-outbox kernel)))
    (sb-thread:with-mutex ((kernel-lock kernel))
      (let ((counts (kernel-counts kernel)))
        (flet ((count-of (what) (gethash what counts 0)))
          (list :requests (hash-table-count (kernel-requests kernel))
                :queued (+ (length (kernel-cpu-queue kernel)) (length (kernel-io-queue kernel)))
                :accepted (count-of 'accepted)
                :rejected (count-of 'rejected)
                :success (count-of 'success)
                :failed (count-of 'failed)
                :cancelled (count-of 'cancelled)
                :peak-queued (count-of 'peak-queued)
                :outbox (outbox-waiting outbox)
                :outbox-peak (outbox-peak outbox)
                :heap (sb-kernel:dynamic-usage)
                :gc-milliseconds (floor (* sb-ext:*gc-run-time* 1000) internal-time-units-per-second)
                :uptime-milliseconds (floor (* (- (get-internal-real-time) (kernel-started kernel)) 1000)
                                            internal-time-units-per-second)))))))

;;;; Parallel work within a request

(defun parallel-map (function list &key (threads 4))
  "Return (mapcar FUNCTION LIST), FUNCTION called on up to THREADS threads at once.
Within a request, it stops at the next `checkpoint' of each thread when
the request is cancelled; an error FUNCTION signals stops every thread
and is signalled again here."
  (let* ((items (coerce list 'simple-vector))
         (count (length items))
         (results (make-array count :initial-element nil))
         (next 0)
         (failure nil)
         (lock (sb-thread:make-mutex :name "parallel-map"))
         (kernel *kernel*)
         (request *request*))
    (flet ((work ()
             (let ((*kernel* kernel)
                   (*request* request))
               (catch 'cancelled
                 (handler-case
                     (loop
                       (let ((index (sb-thread:with-mutex (lock)
                                      (when (and (< next count) (not failure))
                                        (prog1 next (incf next))))))
                         (unless index
                           (return))
                         (setf (svref results index) (funcall function (svref items index)))))
                   (serious-condition (condition)
                     (sb-thread:with-mutex (lock)
                       (setf failure (or failure condition)))))))))
      (let ((helpers (loop repeat (max 0 (min (1- threads) (1- count)))
                           collect (sb-thread:make-thread #'work :name "lispm-kernel helper"))))
        (work)
        (dolist (helper helpers)
          (sb-thread:join-thread helper :default nil))
        (checkpoint)
        (when failure
          (error failure))
        (coerce results 'list)))))

;;;; Emitting

(defun emit (datum)
  "Send DATUM to Emacs as a chunk of the current request.
While Emacs reads slower than chunks come, this waits; a cancelled
request stops here."
  (let ((request *request*))
    (checkpoint)
    (when request
      (outbox-put (kernel-outbox *kernel*)
                  (message-string (list 'chunk (request-id request) datum))
                  :request request)
      (checkpoint))
    datum))

;;;; Messages from Emacs

(defun handle-message (kernel message)
  "Act on MESSAGE, one datum from Emacs.  Return :quit when Emacs asks the
kernel to end.  Signal an error for a malformed one."
  (unless (and (consp message) (keywordp (first message)))
    (error "A message is a list headed by a symbol, not ~S" message))
  (destructuring-bind (head &rest arguments) message
    (ecase head
      (:submit
       (destructuring-bind (id name input &key (owner 0) (generation 0) (priority 0)) arguments
         (check-type id (integer 0))
         (check-type name keyword)
         (check-type owner integer)
         (check-type generation integer)
         (check-type priority (integer -100 100))
         (submit kernel id name input :owner owner :generation generation :priority priority)))
      (:cancel
       (destructuring-bind (id) arguments
         (check-type id (integer 0))
         (cancel kernel id)))
      (:supersede
       (destructuring-bind (owner generation) arguments
         (check-type owner integer)
         (check-type generation integer)
         (supersede kernel owner generation)))
      (:stats
       (outbox-put (kernel-outbox kernel) (message-string (list 'stats (kernel-stats kernel)))))
      (:clear-caches
       (mapc #'funcall *cache-clearers*))
      (:ping
       (outbox-put (kernel-outbox kernel) (message-string (list* 'pong arguments))))
      (:quit :quit))))

(defun handle-line (kernel line)
  "Act on LINE, one message from Emacs; a malformed one is answered with
(protocol-error TEXT).  Return :quit when Emacs asks the kernel to end."
  (handler-case (handle-message kernel (read-message line))
    (error (condition)
      (outbox-put (kernel-outbox kernel)
                  (message-string (list 'protocol-error (condition-text condition))))
      nil)))
