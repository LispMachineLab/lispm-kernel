;;;; runtime.lisp --- CSP request coordinator, worker channels and credit outbox

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

;;; CSP concurrency architecture (zero domain mutexes):
;;;
;;;   P_reader ──control-mbox──▶ P_scheduler ──worker-mbox──▶ P_worker (:cpu/:io)
;;;                                   │                            │
;;;                                   └──ctrl──▶ credit-sink ◀─────┴──chunk (4 MiB)
;;;                                                   │
;;;                                                P_writer ──▶ Emacs
;;;
;;; `P_scheduler' is the single sequential owner of admission state, owner
;;; generations, aging priority queues and counters.  Workers never share or
;;; lock scheduler tables: each idle worker announces readiness on
;;; `control-mbox', receives one assigned request on its private `worker-mbox',
;;; runs it with an explicit `cancel-token', and posts `:settled' back.

(in-package #:lispm-kernel)

(defconstant +protocol+ 1
  "The protocol the kernel speaks; Emacs refuses a kernel of another.")

(defparameter *max-requests* 256
  "Requests accepted and not yet answered, at most.")

(defparameter *max-requests-per-owner* 64
  "Requests of one owner accepted and not yet answered, at most.")

(defparameter *max-reactor-slots* 128
  "Concurrent active multiplexed I/O slots handled by P_reactor, at most.")

(defparameter *exec-stream-credit* (* 256 1024)
  "Per-stream in-flight outbox byte budget before pausing reads on that stream.")

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

(defvar *background-stoppers* '()
  "Functions that stop lazy process-wide helper threads before image save or REPL teardown.")

;;;; Structured conditions

(define-condition kernel-error (error)
  ((message :initarg :message :reader kernel-error-message :type string))
  (:report (lambda (condition stream)
             (write-string (kernel-error-message condition) stream)))
  (:documentation "Base condition for structured errors signalled by the kernel."))

(define-condition message-error (kernel-error)
  ()
  (:documentation "A wire datum that is not a valid protocol message."))

(define-condition job-error (kernel-error)
  ()
  (:documentation "A domain failure raised by a kernel job."))

(define-condition fetch-error (job-error)
  ()
  (:documentation "A download failure in the fetch job."))

(define-condition exec-error (job-error)
  ()
  (:documentation "A process execution failure in the exec or http-stream job."))

(define-condition regex-error (job-error)
  ()
  (:documentation "An invalid regular expression pattern in search-files."))

(defun signal-kernel-error (type control arguments)
  (error type :message (apply #'format nil control arguments)))

(defun message-error (control &rest arguments)
  "Signal `message-error' formatted with CONTROL and ARGUMENTS."
  (signal-kernel-error 'message-error control arguments))

(defun job-error (control &rest arguments)
  "Signal `job-error' formatted with CONTROL and ARGUMENTS."
  (signal-kernel-error 'job-error control arguments))

(defun fetch-error (control &rest arguments)
  "Signal `fetch-error' formatted with CONTROL and ARGUMENTS."
  (signal-kernel-error 'fetch-error control arguments))

(defun exec-error (control &rest arguments)
  "Signal `exec-error' formatted with CONTROL and ARGUMENTS."
  (signal-kernel-error 'exec-error control arguments))

(defun regex-error (control &rest arguments)
  "Signal `regex-error' formatted with CONTROL and ARGUMENTS."
  (signal-kernel-error 'regex-error control arguments))

;;;; Jobs

(defstruct (job (:constructor make-job (name class function)) (:copier nil))
  (name nil :type keyword :read-only t)
  (class :cpu :type (member :cpu :io :reactor) :read-only t)
  (function #'identity :type function :read-only t))

(defvar *jobs* (make-hash-table :test 'eq)
  "The jobs Emacs may ask for, by name.")

(defmacro define-job ((name &key (class :cpu)) (input) &body body)
  "Define the job NAME, which Emacs asks for as (submit ID NAME INPUT ...).
BODY runs on a worker of CLASS, :cpu, :io or :reactor, with INPUT bound to
the datum Emacs sent, and its value is the result Emacs gets.  It may
`emit' chunks before, and calls `checkpoint' between steps, where a
cancelled request stops.  An error it signals fails the request."
  (let ((keyword (intern (string name) :keyword)))
    `(progn
       (setf (gethash ,keyword *jobs*)
             (make-job ,keyword ,class (lambda (,input)
                                         (declare (ignorable ,input))
                                         ,@body)))
       ',name)))

;;;; Requests and cancellation tokens

(defstruct (request (:constructor make-request
                     (id job input owner generation priority
                      &optional chunk-sink done-sink))
                    (:copier nil))
  (id 0 :type integer :read-only t)
  (job nil :type job :read-only t)
  (input nil :read-only t)
  (owner 0 :type integer :read-only t)
  (generation 0 :type integer :read-only t)
  (priority 0 :type integer :read-only t)
  (chunk-sink nil :type (or null function) :read-only t)
  (done-sink nil :type (or null function) :read-only t)
  (submitted (get-internal-real-time) :type integer :read-only t)
  ;; Owned exclusively by P_scheduler (:queued -> :running -> :answered).
  (state :queued :type (member :queued :running :answered))
  ;; Broadcast CSP cancellation channel shared between P_scheduler and P_worker.
  (token (make-cancel-token :name "request-cancel") :type cancel-token :read-only t))

(defun request-cancelled (request)
  "Return true when REQUEST's cancellation token has fired."
  (cancelled-p (request-token request)))

(defun (setf request-cancelled) (value request)
  "Fire REQUEST's cancellation token when VALUE is non-nil."
  (when value
    (cancel! (request-token request)))
  (and value t))

(defvar *request* nil
  "The request this worker currently executes, or nil.")

(defun current-cancel-token ()
  "Return the active `cancel-token' of the current request, or nil."
  (let ((request *request*))
    (and request (request-token request))))

(defun checkpoint ()
  "Stop the current request here when its cancellation token has fired.
Outside a request it does nothing."
  (let ((request *request*))
    (when (and request (cancelled-p (request-token request)))
      (throw 'cancelled nil))))

;;;; Outbox compatibility accessors over `credit-sink'

(declaim (inline outbox-waiting outbox-peak))

(defun outbox-waiting (outbox)
  "Return bytes of chunk output currently buffered in OUTBOX."
  (credit-sink-waiting outbox))

(defun outbox-peak (outbox)
  "Return peak bytes of chunk output buffered in OUTBOX."
  (credit-sink-peak outbox))

;;;; Priority work queues (owned solely by P_scheduler, lock-free by single ownership)

;;; Invariant: (= (work-queue-count q) (length (work-queue-head q)))
;;;            and (eq (work-queue-tail q) (last (work-queue-head q))).
(defstruct (work-queue (:constructor make-work-queue ()) (:copier nil))
  "A FIFO queue of requests supporting O(1) enqueue and aging-priority pop."
  (head '() :type list)
  (tail '() :type list)
  (count 0 :type (integer 0)))

(defun work-queue-push (wq request)
  "Append REQUEST to the tail of WQ in O(1) time."
  (let ((cell (list request)))
    (if (work-queue-tail wq)
        (setf (cdr (work-queue-tail wq)) cell)
        (setf (work-queue-head wq) cell))
    (setf (work-queue-tail wq) cell)
    (incf (work-queue-count wq))
    request))

(defun work-queue-remove (wq target)
  "Remove TARGET from WQ if present; return true when removed."
  (loop with prev = nil
        for cell on (work-queue-head wq)
        when (eq (car cell) target)
          do (if prev
                 (setf (cdr prev) (cdr cell))
                 (setf (work-queue-head wq) (cdr cell)))
             (when (null (cdr cell))
               (setf (work-queue-tail wq) prev))
             (decf (work-queue-count wq))
             (return t)
        do (setf prev cell)))

(defun effective-priority (request now)
  "Return REQUEST's priority at NOW, raised by how long it has waited."
  (+ (request-priority request)
     (floor (* (- now (request-submitted request)) 1000)
            (* *aging-milliseconds* internal-time-units-per-second))))

(defun work-queue-take-best (wq now)
  "Unlink and return the highest effective-priority request in WQ at NOW,
ties broken by oldest arrival."
  (let ((head (work-queue-head wq)))
    (when head
      (let* ((best-cell head)
             (best-prev nil)
             (best-priority (effective-priority (car head) now)))
        (loop for prev = head then cell
              for cell = (cdr head) then (cdr cell)
              while cell
              do (let ((priority (effective-priority (car cell) now)))
                   (when (> priority best-priority)
                     (setf best-cell cell
                           best-prev prev
                           best-priority priority))))
        (if best-prev
            (setf (cdr best-prev) (cdr best-cell))
            (setf (work-queue-head wq) (cdr best-cell)))
        (when (null (cdr best-cell))
          (setf (work-queue-tail wq) best-prev))
        (decf (work-queue-count wq))
        (car best-cell)))))

;;;; Formatting outcomes for the wire

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

;;;; Kernel handle and P_scheduler private state

(defstruct (reactor-handle (:constructor make-reactor-handle (thread submit-fn stop-fn))
                           (:copier nil))
  "Handle to the CSP multiplexed I/O reactor process `P_reactor'."
  (thread nil :read-only t)
  (submit-fn #'identity :type function :read-only t)
  (stop-fn #'identity :type function :read-only t))

(defvar *reactor-starter* nil
  "Function (KERNEL) returning a `reactor-handle', installed by `reactor.lisp'.")

(defstruct (agent-manager-handle
            (:constructor make-agent-manager-handle
             (thread send-fn stop-fn snapshot-fn list-fn))
            (:copier nil))
  "Handle to the CSP agent control-plane actor `P_agents'."
  (thread nil :read-only t)
  (send-fn #'identity :type function :read-only t)
  (stop-fn #'identity :type function :read-only t)
  (snapshot-fn #'identity :type function :read-only t)
  (list-fn #'identity :type function :read-only t))

(defvar *agent-manager-starter* nil
  "Function (KERNEL) returning an `agent-manager-handle', installed by `agent.lisp'.")

(defstruct (kernel (:constructor make-kernel (control outbox subworkers)) (:copier nil))
  "Handle to a running CSP kernel process network."
  (control nil :type mbox :read-only t)
  (outbox nil :type credit-sink :read-only t)
  (subworkers nil :type work-group :read-only t)
  (reactor nil :type (or null reactor-handle))
  (agents nil :type (or null agent-manager-handle))
  (scheduler nil)
  (writer nil)
  (workers '() :type list)
  (started (get-internal-real-time) :type integer :read-only t)
  ;; Bit 0 is 1 while open; upper bits count in-flight `post-control' callers.
  (control-state 1 :type sb-ext:word)
  (closed (make-cancel-token :name "kernel-closed") :type cancel-token :read-only t)
  (final-stats '() :type list))

(defstruct (scheduler-state (:constructor make-scheduler-state
                             (total-workers reactor-live reactor-limit))
                            (:copier nil))
  "Mutable scheduling tables owned exclusively by the sequential P_scheduler process."
  (cpu-queue (make-work-queue) :type work-queue :read-only t)
  (io-queue (make-work-queue) :type work-queue :read-only t)
  (reactor-queue (make-work-queue) :type work-queue :read-only t)
  (idle-cpu '() :type list)
  (idle-io '() :type list)
  (reactor-active 0 :type (integer 0))
  (reactor-limit nil :type (or null (integer 1)) :read-only t)
  (reactor-live nil :type boolean)
  (requests (make-hash-table) :read-only t)
  (generations (make-hash-table) :read-only t)
  (owner-counts (make-hash-table) :read-only t)
  (counts (make-hash-table :test 'eq) :read-only t)
  (live-workers total-workers :type (integer 0))
  (closing nil :type boolean)
  (shutdown-gate nil))

(defvar *kernel* nil
  "The kernel this process runs for Emacs.")

(declaim (ftype (function () null) checkpoint)
         (ftype (function () (or null cancel-token)) current-cancel-token)
         (ftype (function (t) t) emit)
         (ftype (function (function &key (:cpu-workers (integer 0))
                                    (:io-workers (integer 0))
                                    (:subworkers (integer 0))
                                    (:reactor-slots (or null (integer 1))))
                          kernel)
                start-kernel)
         (ftype (function (kernel &key (:timeout (or null real))) kernel) stop-kernel)
         (ftype (function () null) stop-background-helpers)
         (ftype (function (kernel) list) kernel-stats)
         (ftype (function (function list &key (:threads (integer 1))) list) parallel-map)
         (ftype (function (kernel t) t) handle-message)
         (ftype (function (kernel string) t) handle-line))

;;;; Pure/single-owner scheduler transitions

(defun state-queue (state class)
  (ecase class
    (:cpu (scheduler-state-cpu-queue state))
    (:io (scheduler-state-io-queue state))
    (:reactor (scheduler-state-reactor-queue state))))

(defun state-queued-count (state)
  (+ (work-queue-count (scheduler-state-cpu-queue state))
     (work-queue-count (scheduler-state-io-queue state))
     (work-queue-count (scheduler-state-reactor-queue state))))

(defun effective-reactor-limit (state)
  "Return the maximum concurrent reactor slots permitted in STATE."
  (or (scheduler-state-reactor-limit state) *max-reactor-slots*))

(defun pop-idle-worker (state class)
  (ecase class
    (:cpu (pop (scheduler-state-idle-cpu state)))
    (:io (pop (scheduler-state-idle-io state)))))

(defun push-idle-worker (state class worker-mbox)
  (ecase class
    (:cpu (push worker-mbox (scheduler-state-idle-cpu state)))
    (:io (push worker-mbox (scheduler-state-idle-io state)))))

(defun tally-state (state what &optional (amount 1))
  (incf (gethash what (scheduler-state-counts state) 0) amount))

(defun forget-request (state request)
  "Release REQUEST from STATE's admission tables."
  (remhash (request-id request) (scheduler-state-requests state))
  (let ((owner (request-owner request))
        (counts (scheduler-state-owner-counts state)))
    (if (<= (gethash owner counts 0) 1)
        (remhash owner counts)
        (decf (gethash owner counts)))))

(defun settle-request (state outbox request status value)
  "Finalize REQUEST in STATE and post its outcome to `done-sink' or OUTBOX."
  (unless (eq (request-state request) :answered)
    (when (cancelled-p (request-token request))
      (setf status 'cancelled value nil))
    (setf (request-state request) :answered)
    (forget-request state request)
    (tally-state state status)
    (let ((done-sink (request-done-sink request)))
      (if done-sink
          (handler-case (funcall done-sink status value)
            (serious-condition () nil))
          (credit-sink-put-control outbox (final-message request status value))))))

(defun cancel-in-state (state outbox request)
  "Signal REQUEST's cancel token; if still queued, settle it immediately."
  (cancel! (request-token request))
  (when (eq (request-state request) :queued)
    (work-queue-remove (state-queue state (job-class (request-job request))) request)
    (settle-request state outbox request 'cancelled nil)))

(defun supersede-in-state (state outbox owner generation)
  "Advance OWNER to GENERATION in STATE, cancelling all older requests."
  (when (> generation (gethash owner (scheduler-state-generations state) 0))
    (setf (gethash owner (scheduler-state-generations state)) generation)
    (let ((older (loop for request being the hash-values of (scheduler-state-requests state)
                       when (and (= (request-owner request) owner)
                                 (< (request-generation request) generation))
                         collect request)))
      (dolist (request older)
        (cancel-in-state state outbox request)))))

(defun reject-in-state (state outbox id reason &optional done-sink)
  (tally-state state 'rejected)
  (if done-sink
      (handler-case (funcall done-sink 'rejected reason)
        (serious-condition () nil))
      (credit-sink-put-control outbox (message-string (list 'done id 'rejected reason)))))

(defun dispatch-reactor (kernel state)
  "Dispatch queued `:reactor' requests in KERNEL up to STATE's active slot limit."
  (let ((reactor (kernel-reactor kernel))
        (wq (scheduler-state-reactor-queue state))
        (limit (effective-reactor-limit state)))
    (when (and reactor (not (scheduler-state-closing state)))
      (loop while (and (work-queue-head wq)
                       (< (scheduler-state-reactor-active state) limit))
            do (let ((best (work-queue-take-best wq (get-internal-real-time))))
                 (setf (request-state best) :running)
                 (incf (scheduler-state-reactor-active state))
                 (funcall (reactor-handle-submit-fn reactor) best))))))

(defun dispatch-worker-class (state class)
  "Match queued requests of worker CLASS (:cpu or :io) with idle workers."
  (let ((wq (state-queue state class)))
    (loop while (and (work-queue-head wq)
                     (ecase class
                       (:cpu (scheduler-state-idle-cpu state))
                       (:io (scheduler-state-idle-io state))))
          do (let ((worker-mbox (pop-idle-worker state class))
                   (best (work-queue-take-best wq (get-internal-real-time))))
               (setf (request-state best) :running)
               (mbox-send worker-mbox best)))))

(defun dispatch-class (kernel state class)
  "Dispatch queued requests of CLASS in KERNEL and STATE."
  (if (eq class :reactor)
      (dispatch-reactor kernel state)
      (dispatch-worker-class state class)))

(defun submit-in-state (kernel state outbox id name input owner generation priority
                        &optional chunk-sink done-sink)
  "Evaluate admission for request ID in STATE and enqueue or dispatch it."
  (let* ((job (gethash name *jobs*))
         (requests (scheduler-state-requests state))
         (reason (cond ((scheduler-state-closing state) 'closed)
                       ((gethash id requests) 'duplicate)
                       ((null job) 'unknown-job)
                       ((< generation (gethash owner (scheduler-state-generations state) 0))
                        'stale))))
    (unless reason
      (supersede-in-state state outbox owner generation)
      (setf reason
            (cond ((>= (hash-table-count requests) *max-requests*) 'capacity)
                  ((>= (gethash owner (scheduler-state-owner-counts state) 0)
                       *max-requests-per-owner*)
                   'capacity))))
    (if reason
        (reject-in-state state outbox id reason done-sink)
        (let ((request (make-request id job input owner generation priority chunk-sink done-sink))
              (class (job-class job)))
          (setf (gethash id requests) request)
          (incf (gethash owner (scheduler-state-owner-counts state) 0))
          (tally-state state 'accepted)
          (work-queue-push (state-queue state class) request)
          (setf (gethash 'peak-queued (scheduler-state-counts state))
                (max (gethash 'peak-queued (scheduler-state-counts state) 0)
                     (state-queued-count state)))
          (dispatch-class kernel state class)))))

(defun snapshot-stats (kernel state)
  "Build the stats plist from KERNEL and single-owner STATE."
  (let ((outbox (kernel-outbox kernel))
        (counts (scheduler-state-counts state)))
    (flet ((count-of (what) (gethash what counts 0)))
      (list :requests (hash-table-count (scheduler-state-requests state))
            :queued (state-queued-count state)
            :reactor-active (scheduler-state-reactor-active state)
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
                                        internal-time-units-per-second)))))

(defun initiate-shutdown (kernel state outbox gate)
  "Transition STATE into closing mode, cancelling queued and running requests."
  (setf (scheduler-state-closing state) t
        (scheduler-state-shutdown-gate state) gate)
  (let ((active (loop for request being the hash-values of (scheduler-state-requests state)
                      collect request)))
    (dolist (request active)
      (cancel-in-state state outbox request)))
  (dolist (worker-mbox (scheduler-state-idle-cpu state))
    (mbox-send worker-mbox :stop)
    (decf (scheduler-state-live-workers state)))
  (dolist (worker-mbox (scheduler-state-idle-io state))
    (mbox-send worker-mbox :stop)
    (decf (scheduler-state-live-workers state)))
  (setf (scheduler-state-idle-cpu state) '()
        (scheduler-state-idle-io state) '())
  (let ((reactor (kernel-reactor kernel)))
    (when reactor
      (funcall (reactor-handle-stop-fn reactor)))))

(defun scheduler-step (kernel state event)
  "Process one CSP control EVENT in `P_scheduler'."
  (let ((outbox (kernel-outbox kernel)))
    (ecase (first event)
      (:worker-ready
       (destructuring-bind (class worker-mbox) (rest event)
         (if (scheduler-state-closing state)
             (progn
               (mbox-send worker-mbox :stop)
               (decf (scheduler-state-live-workers state)))
             (progn
               (push-idle-worker state class worker-mbox)
               (dispatch-worker-class state class)))))
      (:settled
       (destructuring-bind (request status value) (rest event)
         (settle-request state outbox request status value)))
      (:reactor-settled
       (destructuring-bind (request status value) (rest event)
         (decf (scheduler-state-reactor-active state))
         (settle-request state outbox request status value)
         (dispatch-reactor kernel state)))
      (:reactor-stopped
       (setf (scheduler-state-reactor-live state) nil))
      (:submit
       (destructuring-bind (id name input owner generation priority) (rest event)
         (submit-in-state kernel state outbox id name input owner generation priority)))
      (:submit-internal
       (destructuring-bind (id name input owner generation priority chunk-sink done-sink)
           (rest event)
         (submit-in-state kernel state outbox id name input owner generation priority
                          chunk-sink done-sink)))
      (:cancel
       (let ((request (gethash (second event) (scheduler-state-requests state))))
         (when request
           (cancel-in-state state outbox request))))
      (:supersede
       (destructuring-bind (owner generation) (rest event)
         (supersede-in-state state outbox owner generation)))
      (:malformed
       (destructuring-bind (id error-text) (rest event)
         (credit-sink-put-control outbox (message-string (list 'protocol-error error-text)))
         (when (and id (not (gethash id (scheduler-state-requests state))))
           (reject-in-state state outbox id 'malformed))))
      (:stats-wire
       (credit-sink-put-control outbox
                                (message-string (list 'stats (snapshot-stats kernel state)))))
      (:stats-sync
       (mbox-send (second event) (snapshot-stats kernel state)))
      (:clear-caches
       (mapc #'funcall *cache-clearers*))
      (:ping
       (credit-sink-put-control outbox (message-string (list* 'pong (second event)))))
      (:shutdown
       (initiate-shutdown kernel state outbox (second event))))))

(defun scheduler-loop (kernel total-workers reactor-live reactor-limit)
  "Sequential coordinator process `P_scheduler'."
  (let ((state (make-scheduler-state total-workers reactor-live reactor-limit))
        (control (kernel-control kernel)))
    (loop
      (when (and (scheduler-state-closing state)
                 (zerop (hash-table-count (scheduler-state-requests state)))
                 (<= (scheduler-state-live-workers state) 0)
                 (not (scheduler-state-reactor-live state)))
        (dolist (event (mbox-drain control))
          (scheduler-step kernel state event))
        (setf (kernel-final-stats kernel) (snapshot-stats kernel state))
        (when (scheduler-state-shutdown-gate state)
          (sb-concurrency:open-gate (scheduler-state-shutdown-gate state)))
        (return))
      (scheduler-step kernel state (mbox-recv control)))))

;;;; Worker and Writer processes

(defun run-request (kernel request)
  "Execute REQUEST's job function and return (STATUS VALUE)."
  (let* ((*kernel* kernel)
         (*request* request)
         (outcome (catch 'cancelled
                    (handler-case
                        (list 'success (funcall (job-function (request-job request))
                                                (request-input request)))
                      (serious-condition (condition)
                        (list 'failed (condition-text condition)))))))
    (or outcome (list 'cancelled nil))))

(defun worker-loop (kernel class)
  "Sequential worker process `P_worker': announces readiness, receives one
request on its private mailbox, executes it, and posts `:settled'."
  (let ((control (kernel-control kernel))
        (inbox (make-mbox :name (format nil "~(~A~)-worker" class))))
    (loop
      (mbox-send control (list :worker-ready class inbox))
      (let ((message (mbox-recv inbox)))
        (when (eq message :stop)
          (return))
        (let ((outcome (handler-case (run-request kernel message)
                         (serious-condition (condition)
                           (format *error-output* "lispm-kernel: a worker failed: ~A~%"
                                   (condition-text condition))
                           (list 'failed (condition-text condition))))))
          (mbox-send control (list :settled message (first outcome) (second outcome))))))))

(defun write-loop (outbox sink)
  "Sequential writer process `P_writer': drains OUTBOX into SINK until closed."
  (loop for messages = (credit-sink-take outbox)
        while messages
        do (funcall sink messages)))

(defun start-kernel (sink &key (cpu-workers 2) (io-workers 4) (subworkers 3) reactor-slots)
  "Start a CSP kernel process network and return its handle.
CPU-WORKERS, IO-WORKERS, SUBWORKERS and REACTOR-SLOTS bound the concurrency pools."
  (let* ((control (make-mbox :name "lispm-kernel control"))
         (outbox (make-credit-sink :limit *outbox-limit*))
         (wg (make-work-group :workers subworkers :name "lispm-kernel subworker"))
         (total (+ cpu-workers io-workers))
         (kernel (make-kernel control outbox wg)))
    (when *reactor-starter*
      (setf (kernel-reactor kernel) (funcall *reactor-starter* kernel)))
    (setf (kernel-writer kernel)
          (sb-thread:make-thread #'write-loop
                                 :name "lispm-kernel writer"
                                 :arguments (list outbox sink))
          (kernel-scheduler kernel)
          (sb-thread:make-thread #'scheduler-loop
                                 :name "lispm-kernel scheduler"
                                 :arguments (list kernel total
                                                  (and (kernel-reactor kernel) t)
                                                  reactor-slots)))
    (flet ((spawn-pool (class count)
             (loop for index from 1 to count
                   collect (sb-thread:make-thread
                            #'worker-loop
                            :name (format nil "lispm-kernel ~(~A~) worker ~D" class index)
                            :arguments (list kernel class)))))
      (setf (kernel-workers kernel)
            (append (spawn-pool :cpu cpu-workers) (spawn-pool :io io-workers))))
    (when *agent-manager-starter*
      (setf (kernel-agents kernel) (funcall *agent-manager-starter* kernel)))
    kernel))

(defun close-control-channel (kernel)
  "Seal KERNEL against new `post-control' callers and wait for in-flight sends."
  (loop
    (let ((old (kernel-control-state kernel)))
      (when (not (logbitp 0 old))
        (return))
      (when (eql old (sb-ext:compare-and-swap (kernel-control-state kernel)
                                              old (logand old (lognot 1))))
        (return))))
  (loop until (zerop (ash (kernel-control-state kernel) -1))
        do (sb-thread:thread-yield)))

(defun stop-kernel (kernel &key (timeout 10))
  "Close KERNEL cleanly: cancel active work, join agents, scheduler,
reactor, workers, subworkers and writer within TIMEOUT seconds."
  (when (cancel! (kernel-closed kernel))
    (let ((agents (kernel-agents kernel)))
      (when agents
        (handler-case (funcall (agent-manager-handle-stop-fn agents))
          (serious-condition () nil))
        (when (agent-manager-handle-thread agents)
          (sb-thread:join-thread (agent-manager-handle-thread agents)
                                 :default nil :timeout timeout))))
    (close-control-channel kernel)
    (let ((gate (sb-concurrency:make-gate :name "kernel-shutdown" :open nil)))
      (mbox-send (kernel-control kernel) (list :shutdown gate))
      (sb-concurrency:wait-on-gate gate :timeout timeout)
      (dolist (worker (kernel-workers kernel))
        (sb-thread:join-thread worker :default nil :timeout timeout))
      (let ((reactor (kernel-reactor kernel)))
        (when (and reactor (reactor-handle-thread reactor))
          (sb-thread:join-thread (reactor-handle-thread reactor) :default nil :timeout timeout)))
      (sb-thread:join-thread (kernel-scheduler kernel) :default nil :timeout timeout)
      (stop-work-group (kernel-subworkers kernel) :timeout timeout)
      (credit-sink-close (kernel-outbox kernel))
      (sb-thread:join-thread (kernel-writer kernel) :default nil :timeout timeout)))
  kernel)

(defun kernel-stats (kernel)
  "Ask KERNEL's coordinator for a consistent stats plist."
  (if (cancelled-p (kernel-closed kernel))
      (kernel-final-stats kernel)
      (let ((reply (make-mbox :name "stats-reply")))
        (mbox-send (kernel-control kernel) (list :stats-sync reply))
        (or (mbox-recv reply :timeout 5) (kernel-final-stats kernel)))))

;;;; Parallel work within a request (persistent work-group + caller work-helping)

(defvar *standalone-subworkers* nil
  "Lazy persistent work-group used only when `parallel-map' is called outside a kernel.")

(defun stop-standalone-subworkers ()
  "Stop any standalone work-group before saving an SBCL core image."
  (let ((wg *standalone-subworkers*))
    (when wg
      (setf *standalone-subworkers* nil)
      (stop-work-group wg :timeout 2))))

(defun stop-background-helpers ()
  "Stop all lazy process-wide background helper pools (`*standalone-subworkers*', `P_cache')."
  (mapc #'funcall *background-stoppers*)
  nil)

(pushnew 'stop-standalone-subworkers *background-stoppers*)
(pushnew 'stop-background-helpers sb-ext:*save-hooks*)

(defun current-work-group ()
  (if *kernel*
      (kernel-subworkers *kernel*)
      (or *standalone-subworkers*
          (let ((fresh (make-work-group :workers 3 :name "lispm-kernel standalone-subworker")))
            (if (eq nil (sb-ext:compare-and-swap *standalone-subworkers* nil fresh))
                fresh
                (progn
                  (stop-work-group fresh :timeout 1)
                  *standalone-subworkers*))))))

(defun parallel-map (function list &key (threads 4))
  "Return (mapcar FUNCTION LIST) across persistent CSP subworkers plus the
calling thread (work-helping), without spawning per-request OS threads."
  (let* ((kernel *kernel*)
         (request *request*)
         (token (and request (request-token request)))
         (wg (current-work-group)))
    (checkpoint)
    (let ((results (work-group-map
                    wg function list
                    :threads threads
                    :token token
                    :context (lambda (thunk)
                               (let ((*kernel* kernel)
                                     (*request* request))
                                 (catch 'cancelled
                                   (funcall thunk)))))))
      (checkpoint)
      results)))

;;;; Emitting chunks

(defun emit (datum)
  "Send DATUM to Emacs (or the request's internal `chunk-sink') as a chunk.
Applies byte-credit backpressure against `*outbox-limit*' when writing to
Emacs and wakes immediately if the request's cancellation token fires."
  (let ((request *request*))
    (checkpoint)
    (when request
      (let ((sink (request-chunk-sink request)))
        (if sink
            (funcall sink datum)
            (credit-sink-put-chunk (kernel-outbox *kernel*)
                                   (message-string (list 'chunk (request-id request) datum))
                                   :token (request-token request)
                                   :limit *outbox-limit*)))
      (checkpoint))
    datum))

;;;; Messages from Emacs (P_reader -> P_scheduler / P_agents channels)

(defun post-control (kernel event)
  "Send EVENT to KERNEL's coordinator, or handle closed-kernel rejection.
Uses lock-free sender pinning so every accepted EVENT arrives before `:shutdown'."
  (loop
    (let ((old (kernel-control-state kernel)))
      (unless (logbitp 0 old)
        (case (first event)
          (:submit
           (credit-sink-put-control
            (kernel-outbox kernel)
            (message-string (list 'done (second event) 'rejected 'closed))))
          (:submit-internal
           (let ((done-sink (eighth event)))
             (when done-sink
               (handler-case (funcall done-sink 'rejected 'closed)
                 (serious-condition () nil))))))
        (return nil))
      (when (eql old (sb-ext:compare-and-swap (kernel-control-state kernel) old (+ old 2)))
        (unwind-protect
             (mbox-send (kernel-control kernel) event)
          (sb-ext:atomic-decf (kernel-control-state kernel) 2))
        (return t)))))

(defun send-agent-command (kernel command)
  "Forward COMMAND to KERNEL's `P_agents' coordinator if active and open."
  (let ((agents (kernel-agents kernel)))
    (when (and agents (logbitp 0 (kernel-control-state kernel)))
      (funcall (agent-manager-handle-send-fn agents) command)
      t)))

(defun handle-message (kernel message)
  "Validate MESSAGE from Emacs and forward it to `P_scheduler' or `P_agents'.
Return :quit when Emacs asks the kernel to end."
  (unless (and (consp message) (keywordp (first message)))
    (message-error "A message is a list headed by a symbol, not ~S" message))
  (destructuring-bind (head &rest arguments) message
    (ecase head
      (:submit
       (destructuring-bind (id name input &key (owner 0) (generation 0) (priority 0)) arguments
         (check-type id (integer 0))
         (check-type name keyword)
         (check-type owner integer)
         (check-type generation integer)
         (check-type priority (integer -100 100))
         (post-control kernel (list :submit id name input owner generation priority))))
      (:cancel
       (destructuring-bind (id) arguments
         (check-type id (integer 0))
         (post-control kernel (list :cancel id))))
      (:supersede
       (destructuring-bind (owner generation) arguments
         (check-type owner integer)
         (check-type generation integer)
         (post-control kernel (list :supersede owner generation))))
      (:stats
       (post-control kernel '(:stats-wire)))
      (:clear-caches
       (post-control kernel '(:clear-caches)))
      (:ping
       (post-control kernel (list :ping arguments)))
      (:agent-start
       (destructuring-bind (session config) arguments
         (check-type session string)
         (check-type config list)
         (send-agent-command kernel (list :agent-start session config))))
      (:agent-turn
       (destructuring-bind (session input) arguments
         (check-type session string)
         (check-type input list)
         (send-agent-command kernel (list :agent-turn session input))))
      (:agent-cancel
       (destructuring-bind (session) arguments
         (check-type session string)
         (send-agent-command kernel (list :agent-cancel session))))
      (:agent-effect-reply
       (destructuring-bind (session effect-id status result) arguments
         (check-type session string)
         (check-type effect-id integer)
         (check-type status keyword)
         (send-agent-command kernel (list :agent-effect-reply session effect-id status result))))
      (:agent-approval-decision
       (destructuring-bind (session call-id decision &key reason) arguments
         (check-type session string)
         (check-type call-id string)
         (check-type decision keyword)
         (send-agent-command kernel (list :agent-approval-decision session call-id decision reason))))
      (:agent-viewport-subscribe
       (destructuring-bind (session mode) arguments
         (check-type session string)
         (check-type mode keyword)
         (send-agent-command kernel (list :agent-viewport-subscribe session mode))))
      (:agent-resync
       (destructuring-bind (session &key since-seq) arguments
         (check-type session string)
         (check-type since-seq (or null integer))
         (send-agent-command kernel (list :agent-resync session since-seq))))
      (:agent-list
       (when arguments
         (message-error "(agent-list) takes no arguments"))
       (send-agent-command kernel '(:agent-list)))
      (:agent-stop
       (destructuring-bind (session) arguments
         (check-type session string)
         (send-agent-command kernel (list :agent-stop session))))
      (:quit :quit))))

(defun submit-id (line)
  "Return the request ID of LINE when it starts as (submit ID, else nil."
  (let ((prefix "(submit "))
    (when (and (> (length line) (length prefix))
               (string= prefix line :end2 (length prefix)))
      (let ((end (position-if-not #'digit-char-p line :start (length prefix))))
        (when (and end (> end (length prefix))
                   (member (char line end) '(#\Space #\Tab #\( #\" #\[)))
          (parse-integer line :start (length prefix) :end end))))))

(defun handle-line (kernel line)
  "Parse LINE from Emacs and send the resulting command or `:malformed' event
to `P_scheduler'.  Return :quit when Emacs asks the kernel to end."
  (handler-case (handle-message kernel (read-message line))
    (error (condition)
      (post-control kernel (list :malformed (submit-id line) (condition-text condition)))
      nil)))
