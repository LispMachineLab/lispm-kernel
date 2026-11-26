;;;; reactor.lisp --- Single-actor multiplexed non-blocking I/O reactor

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

;;; CSP multiplexed I/O actor `P_reactor':
;;;
;;;   P_scheduler ──(:start req)──▶ P_reactor ──(poll 2 + timer)──▶ try-put-chunk ──▶ P_writer
;;;        ▲                              │                                                  │
;;;        └──(:reactor-settled req ...)──┴──────◀────── credit-sink room hook ◀─────────────┘
;;;
;;; One dedicated actor thread owns every active subprocess descriptor table
;;; without mutexes.  Each stream carries an independent `stream-credit'
;;; budget so backpressure pauses only that stream's `output-fd' reads while
;;; sibling streams, cancellation, timeouts and exits continue uninterrupted.

(in-package #:lispm-kernel)

(defparameter *reactor-reads-per-tick* 4
  "Maximum consecutive `read(2)' calls per live stream per reactor tick.")

(defstruct (reactor-slot (:constructor %make-reactor-slot
                          (request stderr-ring credit
                           &key program timeout cleanup-path process deadline
                                stdin-stream stdin-octets stdin-fd
                                (stdin-pos 0) stdin-open
                                (output-fd -1) (output-buf #())
                                error-fd errors-open
                                chunk-transform finish-transform))
                         (:copier nil))
  "Single-owner descriptor state for one active `:reactor' request."
  (request nil :type request :read-only t)
  (program "" :type string :read-only t)
  (timeout nil :type (or null integer) :read-only t)
  (cleanup-path nil :type (or null string) :read-only t)
  (chunk-transform nil :type (or null function) :read-only t)
  (finish-transform nil :type (or null function) :read-only t)
  (transformed nil :type boolean)
  (process nil)
  (state :running :type (member :running :draining :terminating))
  (deadline nil :type (or null integer))
  (kill-deadline nil :type (or null integer))
  (killed nil :type boolean)
  (term-status 'cancelled :type symbol)
  (term-value nil)
  (stdin-stream nil)
  (stdin-octets nil)
  (stdin-fd nil :type (or null fixnum))
  (stdin-pos 0 :type fixnum)
  (stdin-open nil :type boolean)
  (output-fd -1 :type fixnum :read-only t)
  (output-open t :type boolean)
  (output-buf #() :type (simple-array (unsigned-byte 8) (*)) :read-only t)
  (carried 0 :type fixnum)
  (error-fd nil :type (or null fixnum) :read-only t)
  (errors-open nil :type boolean)
  (stderr-ring (make-byte-ring 0) :type byte-ring :read-only t)
  (credit (make-stream-credit :limit 0) :type stream-credit :read-only t)
  (pending-wire nil :type list)
  (stdin-poll-idx -1 :type fixnum)
  (output-poll-idx -1 :type fixnum)
  (error-poll-idx -1 :type fixnum)
  (stdin-ready nil :type boolean)
  (output-ready nil :type boolean)
  (error-ready nil :type boolean))

(defstruct (reactor (:constructor %make-reactor (kernel inbox pipe)) (:copier nil))
  "Single-owner CSP reactor actor state driven by `reactor-loop'."
  (kernel nil :type kernel :read-only t)
  (inbox nil :type mbox :read-only t)
  (pipe nil :type wakeup-pipe :read-only t)
  (slots (make-array 16 :adjustable t :fill-pointer 0))
  (pollbuf (make-array (* 8 256) :element-type '(unsigned-byte 8) :initial-element 0)
   :type (simple-array (unsigned-byte 8) (*)))
  (scratch (make-array 4096 :element-type '(unsigned-byte 8))
   :type (simple-array (unsigned-byte 8) (*)) :read-only t)
  (rr-cursor 0 :type fixnum)
  (stopping nil :type boolean))

;;;; Small predicates and resource guards

(defun unlink-cleanup-path (path)
  "Remove temporary request file PATH if non-nil, ignoring missing-file errors."
  (when path
    (handler-case (sb-posix:unlink path)
      (sb-posix:syscall-error () nil))))

(defun close-stdin-silently (slot)
  "Close SLOT's child stdin stream if still open."
  (when (reactor-slot-stdin-stream slot)
    (handler-case (close (reactor-slot-stdin-stream slot) :abort t)
      (stream-error () nil))
    (setf (reactor-slot-stdin-stream slot) nil
          (reactor-slot-stdin-open slot) nil)))

(defun slot-deadline-expired-p (slot now)
  "Return true when SLOT has a finite deadline at or before NOW."
  (let ((deadline (reactor-slot-deadline slot)))
    (and deadline (>= now deadline))))

(defun slot-cancelled-p (slot)
  "Return true when SLOT's request cancellation token has fired."
  (cancelled-p (request-token (reactor-slot-request slot))))

(defun slot-backpressured-p (slot)
  "Return true when SLOT is waiting on outbox room for a pending chunk."
  (not (null (reactor-slot-pending-wire slot))))

(defun reactor-post-settled (reactor request status value)
  "Report completion of REQUEST to `P_scheduler'."
  (mbox-send (kernel-control (reactor-kernel reactor))
             (list :reactor-settled request status value)))

(defun process-exit-plist (process stderr-ring)
  "Return `(:signal N :stderr ...)' or `(:exit CODE :stderr ...)' for PROCESS."
  (let ((stderr (byte-ring-string stderr-ring)))
    (if (eq (sb-ext:process-status process) :signaled)
        (list :signal (sb-ext:process-exit-code process) :stderr stderr)
        (list :exit (sb-ext:process-exit-code process) :stderr stderr))))

;;;; Outbox streaming and per-stream backpressure

(defun slot-try-send-wires (reactor slot wires)
  "Attempt non-blocking send of WIRES (list of wire strings) for SLOT.
Return `:sent', `:full', `:cancelled', or `:closed'."
  (let* ((kernel (reactor-kernel reactor))
         (req (reactor-slot-request slot))
         (outbox (kernel-outbox kernel))
         (token (request-token req))
         (credit (reactor-slot-credit slot)))
    (setf (reactor-slot-pending-wire slot) nil)
    (loop for cell on wires
          for outcome = (credit-sink-try-put-chunk outbox (car cell)
                                                   :token token
                                                   :limit *outbox-limit*
                                                   :stream-credit credit)
          do (case outcome
               (:full
                (setf (reactor-slot-pending-wire slot) cell)
                (return-from slot-try-send-wires :full))
               ((:cancelled :closed)
                (return-from slot-try-send-wires outcome))))
    :sent))

(defun slot-try-emit (reactor slot text)
  "Transform or format TEXT as chunk(s) for SLOT and emit without blocking."
  (let* ((req (reactor-slot-request slot))
         (chunk-sink (request-chunk-sink req)))
    (when chunk-sink
      (funcall chunk-sink text)
      (return-from slot-try-emit :sent))
    (let* ((transform (reactor-slot-chunk-transform slot))
           (items (if transform (funcall transform text) (list text)))
           (id (request-id req))
           (wires (loop for item in items
                        collect (message-string (list 'chunk id item)))))
      (if wires
          (slot-try-send-wires reactor slot wires)
          :sent))))

(defun slot-flush-pending (reactor slot)
  "Flush SLOT's held pending wires if present; return outcome or `:empty'."
  (let ((pending (reactor-slot-pending-wire slot)))
    (if pending
        (slot-try-send-wires reactor slot pending)
        :empty)))

(defun slot-drain-stdout (reactor slot max-reads)
  "Drain stdout from SLOT up to MAX-READS times (or until EOF/block when nil)."
  (let ((fd (reactor-slot-output-fd slot))
        (buf (reactor-slot-output-buf slot))
        (reads 0))
    (loop while (and (reactor-slot-output-open slot)
                     (not (slot-backpressured-p slot))
                     (or (null max-reads) (< reads max-reads)))
          do (incf reads)
             (let ((count (read-nonblocking fd buf (reactor-slot-carried slot))))
               (cond ((eq count :would-block)
                      (return))
                     ((zerop count)
                      (setf (reactor-slot-output-open slot) nil)
                      (let ((carried (reactor-slot-carried slot)))
                        (when (plusp carried)
                          (setf (reactor-slot-carried slot) 0)
                          (slot-try-emit reactor slot (utf-8-text buf 0 carried))))
                      (return))
                     (t
                      (let* ((end (+ (reactor-slot-carried slot) count))
                             (whole (complete-utf-8-end buf end))
                             (rem (- end whole)))
                        (if (plusp whole)
                            (let ((text (utf-8-text buf 0 whole)))
                              (replace buf buf :start2 whole :end2 end)
                              (setf (reactor-slot-carried slot) rem)
                              (unless (eq (slot-try-emit reactor slot text) :sent)
                                (return)))
                            (setf (reactor-slot-carried slot) rem)))))))))

(defun slot-drain-stderr (slot scratch &optional max-reads)
  "Drain octets from SLOT's stderr into its ring, capped at MAX-READS when non-nil."
  (let ((fd (reactor-slot-error-fd slot))
        (ring (reactor-slot-stderr-ring slot))
        (reads 0))
    (when fd
      (loop while (and (reactor-slot-errors-open slot)
                       (or (null max-reads) (< reads max-reads)))
            do (incf reads)
               (let ((count (read-nonblocking fd scratch 0)))
                 (cond ((eq count :would-block) (return))
                       ((zerop count)
                        (setf (reactor-slot-errors-open slot) nil)
                        (return))
                       (t (byte-ring-write ring scratch count))))))))

;;;; Slot lifecycle: spawn, run, drain, terminate, finish

(defun reactor-finish-slot (reactor slot status value)
  "Reap SLOT's process, release temp resources, and settle with STATUS and VALUE.
Always return nil to mark the slot removed."
  (let ((process (reactor-slot-process slot)))
    (close-stdin-silently slot)
    (when process
      (handler-case
          (progn
            (unless (sb-ext:process-alive-p process)
              (sb-ext:process-wait process))
            (sb-ext:process-close process))
        (serious-condition () nil)))
    (unlink-cleanup-path (reactor-slot-cleanup-path slot))
    (reactor-post-settled reactor (reactor-slot-request slot) status value)
    nil))

(defun slot-apply-finish-transform (slot status value)
  "Apply SLOT's optional `finish-transform' at most once.
Return (values NEW-STATUS NEW-VALUE TRAILING-WIRES)."
  (let ((transform (reactor-slot-finish-transform slot)))
    (if (and transform (not (reactor-slot-transformed slot)))
        (progn
          (setf (reactor-slot-transformed slot) t)
          (multiple-value-bind (new-status new-value trailing)
              (funcall transform status value)
            (let* ((req (reactor-slot-request slot))
                   (chunk-sink (request-chunk-sink req))
                   (id (request-id req)))
              (when (and chunk-sink trailing)
                (dolist (item trailing)
                  (funcall chunk-sink item))
                (setf trailing nil))
              (values new-status new-value
                      (and trailing
                           (loop for item in trailing
                                 collect (message-string (list 'chunk id item))))))))
        (values status value nil))))

(defun slot-begin-terminate (reactor slot status value now)
  "Transition SLOT into graceful SIGTERM -> SIGKILL termination, or reap immediately."
  (let ((process (reactor-slot-process slot)))
    (when (eq status 'failed)
      (multiple-value-setq (status value)
        (slot-apply-finish-transform slot status value)))
    (setf (reactor-slot-pending-wire slot) nil
          (reactor-slot-stdin-open slot) nil
          (reactor-slot-output-open slot) nil
          (reactor-slot-errors-open slot) nil
          (reactor-slot-term-status slot) status
          (reactor-slot-term-value slot) value)
    (close-stdin-silently slot)
    (cond ((and process (sb-ext:process-alive-p process))
           (handler-case (sb-ext:process-kill process sb-posix:sigterm :process-group)
             (serious-condition () nil))
           (setf (reactor-slot-state slot) :terminating
                 (reactor-slot-killed slot) nil
                 (reactor-slot-kill-deadline slot)
                 (+ now (* *exec-kill-seconds* internal-time-units-per-second)))
           t)
          (t
           (reactor-finish-slot reactor slot status value)))))

(defun slot-step-terminating (reactor slot now)
  "Progress a `:terminating' slot; escalate to SIGKILL once `kill-deadline' passes."
  (let ((process (reactor-slot-process slot)))
    (cond ((or (null process) (not (sb-ext:process-alive-p process)))
           (reactor-finish-slot reactor slot
                                (reactor-slot-term-status slot)
                                (reactor-slot-term-value slot)))
          ((and (not (reactor-slot-killed slot))
                (reactor-slot-kill-deadline slot)
                (>= now (reactor-slot-kill-deadline slot)))
           (handler-case (sb-ext:process-kill process sb-posix:sigkill :process-group)
             (serious-condition () nil))
           (setf (reactor-slot-killed slot) t
                 (reactor-slot-kill-deadline slot) nil)
           ;; Let `:status-hook' reap asynchronously via `SIGCHLD' rather than
           ;; blocking `P_reactor' inside `sb-ext:process-wait'.
           (if (not (sb-ext:process-alive-p process))
               (reactor-finish-slot reactor slot
                                    (reactor-slot-term-status slot)
                                    (reactor-slot-term-value slot))
               t))
          (t t))))

(defun slot-step-draining (reactor slot)
  "Flush final pending chunk for an exited process before settling it."
  (when (slot-cancelled-p slot)
    (setf (reactor-slot-pending-wire slot) nil)
    (return-from slot-step-draining
      (reactor-finish-slot reactor slot 'cancelled nil)))
  (let ((outcome (slot-flush-pending reactor slot)))
    (case outcome
      (:full t)
      ((:cancelled :closed)
       (setf (reactor-slot-pending-wire slot) nil)
       (reactor-finish-slot reactor slot 'cancelled nil))
      (otherwise
       (reactor-finish-slot reactor slot
                            (reactor-slot-term-status slot)
                            (reactor-slot-term-value slot))))))

(defun slot-handle-exit (reactor slot scratch)
  "Finalize I/O after SLOT's child process exits, pausing only for backpressure."
  (let ((process (reactor-slot-process slot)))
    (slot-flush-pending reactor slot)
    (unless (slot-backpressured-p slot)
      (when (reactor-slot-output-open slot)
        (slot-drain-stdout reactor slot nil)))
    (when (reactor-slot-errors-open slot)
      (slot-drain-stderr slot scratch nil))
    (when (slot-backpressured-p slot)
      (when (slot-cancelled-p slot)
        (return-from slot-handle-exit (slot-begin-terminate reactor slot 'cancelled nil 0)))
      (when (and (not (reactor-slot-output-open slot)) (not (reactor-slot-errors-open slot)))
        (close-stdin-silently slot)
        (sb-ext:process-wait process)
        (multiple-value-bind (status value trailing)
            (slot-apply-finish-transform slot 'success
                                         (process-exit-plist process (reactor-slot-stderr-ring slot)))
          (when trailing
            (setf (reactor-slot-pending-wire slot)
                  (append (reactor-slot-pending-wire slot) trailing)))
          (setf (reactor-slot-state slot) :draining
                (reactor-slot-term-status slot) status
                (reactor-slot-term-value slot) value)))
      (return-from slot-handle-exit t))
    (when (plusp (reactor-slot-carried slot))
      (let ((buf (reactor-slot-output-buf slot))
            (carried (reactor-slot-carried slot)))
        (setf (reactor-slot-carried slot) 0)
        (slot-try-emit reactor slot (utf-8-text buf 0 carried))))
    (setf (reactor-slot-output-open slot) nil
          (reactor-slot-errors-open slot) nil)
    (close-stdin-silently slot)
    (sb-ext:process-wait process)
    (multiple-value-bind (status value trailing)
        (slot-apply-finish-transform slot 'success
                                     (process-exit-plist process (reactor-slot-stderr-ring slot)))
      (when trailing
        (if (slot-backpressured-p slot)
            (setf (reactor-slot-pending-wire slot)
                  (append (reactor-slot-pending-wire slot) trailing))
            (slot-try-send-wires reactor slot trailing)))
      (cond ((slot-backpressured-p slot)
             (setf (reactor-slot-state slot) :draining
                   (reactor-slot-term-status slot) status
                   (reactor-slot-term-value slot) value)
             t)
            (t
             (reactor-finish-slot reactor slot status value))))))

(defun slot-pump-stdin-if-ready (slot)
  "Feed SLOT's stdin descriptor when ready and open."
  (when (and (reactor-slot-stdin-open slot) (reactor-slot-stdin-ready slot))
    (setf (reactor-slot-stdin-ready slot) nil)
    (multiple-value-bind (open-p next-pos)
        (pump-stdin-fd (reactor-slot-stdin-fd slot)
                       (reactor-slot-stdin-octets slot)
                       (reactor-slot-stdin-pos slot)
                       (reactor-slot-stdin-stream slot)
                       *reactor-reads-per-tick*)
      (setf (reactor-slot-stdin-open slot) open-p
            (reactor-slot-stdin-pos slot) next-pos)
      (unless open-p
        (setf (reactor-slot-stdin-stream slot) nil)))))

(defun slot-step-running (reactor slot scratch now)
  "Advance one `:running' reactor SLOT; return t while active, nil once settled."
  (when (slot-cancelled-p slot)
    (return-from slot-step-running (slot-begin-terminate reactor slot 'cancelled nil now)))
  (let ((process (reactor-slot-process slot)))
    (when (and (sb-ext:process-alive-p process)
               (slot-deadline-expired-p slot now))
      (return-from slot-step-running
        (slot-begin-terminate
         reactor slot 'failed
         (format nil "~A did not finish in ~D seconds"
                 (reactor-slot-program slot) (reactor-slot-timeout slot))
         now))))
  (handler-case
      (let ((was-backpressured (slot-backpressured-p slot))
            (flush-outcome (if (slot-backpressured-p slot)
                               (slot-flush-pending reactor slot)
                               :empty)))
        (slot-pump-stdin-if-ready slot)
        (when (and (not (slot-backpressured-p slot))
                   (reactor-slot-output-open slot)
                   (or (reactor-slot-output-ready slot)
                       (and was-backpressured (eq flush-outcome :sent))))
          (setf (reactor-slot-output-ready slot) nil)
          (slot-drain-stdout reactor slot *reactor-reads-per-tick*))
        (when (and (reactor-slot-errors-open slot) (reactor-slot-error-ready slot))
          (setf (reactor-slot-error-ready slot) nil)
          (slot-drain-stderr slot scratch *reactor-reads-per-tick*))
        (if (sb-ext:process-alive-p (reactor-slot-process slot))
            t
            (slot-handle-exit reactor slot scratch)))
    (serious-condition (condition)
      (slot-begin-terminate reactor slot 'failed (condition-text condition) now))))

(defun reactor-step-slot (reactor slot scratch now)
  "Step SLOT according to its current state; return nil when retired."
  (ecase (reactor-slot-state slot)
    (:running (slot-step-running reactor slot scratch now))
    (:draining (slot-step-draining reactor slot))
    (:terminating (slot-step-terminating reactor slot now))))

;;;; Starting and shutting down slots

(defun build-slot-from-process (request spec process)
  "Wrap running PROCESS spawned for REQUEST and SPEC into a `reactor-slot'."
  (let* ((stdin-str (exec-spec-stdin spec))
         (stdin-stream (and stdin-str (sb-ext:process-input process)))
         (stdin-octets (and stdin-str (sb-ext:string-to-octets stdin-str :external-format :utf-8)))
         (stdin-fd (and stdin-stream (sb-sys:fd-stream-fd stdin-stream)))
         (output-fd (sb-sys:fd-stream-fd (sb-ext:process-output process)))
         (err-stream (and (not (exec-spec-combine-error spec)) (sb-ext:process-error process)))
         (error-fd (and err-stream (sb-sys:fd-stream-fd err-stream)))
         (timeout (exec-spec-timeout spec))
         (deadline (and timeout (+ (get-internal-real-time)
                                   (* timeout internal-time-units-per-second))))
         (stdin-open (and stdin-fd t))
         (stdin-pos 0))
    (when stdin-fd
      (set-fd-nonblocking stdin-fd)
      (multiple-value-setq (stdin-open stdin-pos)
        (pump-stdin-fd stdin-fd stdin-octets 0 stdin-stream *reactor-reads-per-tick*)))
    (set-fd-nonblocking output-fd)
    (when error-fd
      (set-fd-nonblocking error-fd))
    (%make-reactor-slot
     request
     (make-byte-ring *exec-stderr-limit*)
     (make-stream-credit :limit *exec-stream-credit*)
     :program (exec-spec-program spec)
     :timeout timeout
     :cleanup-path (exec-spec-cleanup-path spec)
     :chunk-transform (exec-spec-chunk-transform spec)
     :finish-transform (exec-spec-finish-transform spec)
     :process process
     :deadline deadline
     :stdin-stream (and stdin-open stdin-stream)
     :stdin-octets stdin-octets
     :stdin-fd stdin-fd
     :stdin-pos stdin-pos
     :stdin-open stdin-open
     :output-fd output-fd
     :output-buf (make-array (max 4 (+ *exec-read-octets* 3)) :element-type '(unsigned-byte 8))
     :error-fd error-fd
     :errors-open (and error-fd t))))

(defun reactor-start-slot (reactor request)
  "Validate REQUEST, spawn its non-blocking child process, and enroll its slot."
  (let ((token (request-token request))
        (pipe (reactor-pipe reactor))
        (spec nil)
        (process nil)
        (enrolled nil))
    (when (cancelled-p token)
      (reactor-post-settled reactor request 'cancelled nil)
      (return-from reactor-start-slot nil))
    (handler-case
        (setf spec (funcall (job-function (request-job request)) (request-input request)))
      (serious-condition (condition)
        (reactor-post-settled reactor request 'failed (condition-text condition))
        (return-from reactor-start-slot nil)))
    (unwind-protect
         (progn
           (unless (register-cancel-hook token (lambda () (wakeup-poke pipe)))
             (reactor-post-settled reactor request 'cancelled nil)
             (return-from reactor-start-slot nil))
           (when (cancelled-p token)
             (reactor-post-settled reactor request 'cancelled nil)
             (return-from reactor-start-slot nil))
           (handler-case
               (progn
                 (setf process
                       (sb-ext:run-program
                        (exec-spec-program spec) (exec-spec-args spec)
                        :search (exec-spec-search spec)
                        :wait nil
                        :directory (exec-spec-cwd spec)
                        :environment (exec-spec-env spec)
                        :input (if (exec-spec-stdin spec) :stream nil)
                        :output :stream
                        :error (if (exec-spec-combine-error spec) :output :stream)
                        :external-format '(:utf-8 :replacement #\?)
                        :status-hook (lambda (proc)
                                       (unless (sb-ext:process-alive-p proc)
                                         (wakeup-poke pipe)))))
                 (vector-push-extend (build-slot-from-process request spec process)
                                     (reactor-slots reactor))
                 (setf enrolled t))
             (serious-condition (condition)
               (reactor-post-settled reactor request 'failed (condition-text condition)))))
      (unless enrolled
        (when process
          (handler-case
              (progn
                (when (sb-ext:process-alive-p process)
                  (sb-ext:process-kill process sb-posix:sigkill :process-group))
                (unless (sb-ext:process-alive-p process)
                  (sb-ext:process-wait process))
                (sb-ext:process-close process))
            (serious-condition () nil)))
        (unlink-cleanup-path (exec-spec-cleanup-path spec))))))

(defun force-cleanup-slots (reactor)
  "Force-kill and reap any remaining slots during abnormal reactor teardown."
  (let ((slots (reactor-slots reactor)))
    (loop for idx below (length slots)
          for slot = (aref slots idx)
          for proc = (reactor-slot-process slot)
          do (close-stdin-silently slot)
             (when proc
               (handler-case
                   (progn
                     (when (sb-ext:process-alive-p proc)
                       (sb-ext:process-kill proc sb-posix:sigkill :process-group)
                       (sb-ext:process-wait proc))
                     (sb-ext:process-close proc))
                 (serious-condition () nil)))
             (unlink-cleanup-path (reactor-slot-cleanup-path slot)))
    (setf (fill-pointer slots) 0)))

;;;; Poll array assembly, timeout computation, and round-robin stepping

(defun ensure-reactor-pollbuf (reactor count)
  "Ensure REACTOR's `poll(2)' buffer can hold at least COUNT entries."
  (let ((needed (* 8 count))
        (buf (reactor-pollbuf reactor)))
    (when (> needed (length buf))
      (let ((new-size (max needed (* 2 (length buf)))))
        (setf (reactor-pollbuf reactor)
              (make-array new-size :element-type '(unsigned-byte 8) :initial-element 0))))
    (reactor-pollbuf reactor)))

(defun fill-reactor-pollbuf (reactor)
  "Populate REACTOR's `pollbuf' with wakeup pipe and ready-to-poll slot fds; return NFDS."
  (let* ((slots (reactor-slots reactor))
         (max-fds (+ 1 (* 3 (length slots))))
         (pollbuf (ensure-reactor-pollbuf reactor max-fds))
         (nfds 1))
    (sb-sys:with-pinned-objects (pollbuf)
      (set-pollfd pollbuf 0 (wakeup-pipe-rfd (reactor-pipe reactor)) +pollin+)
      (loop for idx below (length slots)
            for slot = (aref slots idx)
            do (setf (reactor-slot-stdin-poll-idx slot) -1
                     (reactor-slot-output-poll-idx slot) -1
                     (reactor-slot-error-poll-idx slot) -1)
               (when (eq (reactor-slot-state slot) :running)
                 (when (reactor-slot-stdin-open slot)
                   (setf (reactor-slot-stdin-poll-idx slot) nfds)
                   (set-pollfd pollbuf nfds (reactor-slot-stdin-fd slot) +pollout+)
                   (incf nfds))
                 (when (and (reactor-slot-output-open slot)
                            (not (slot-backpressured-p slot)))
                   (setf (reactor-slot-output-poll-idx slot) nfds)
                   (set-pollfd pollbuf nfds (reactor-slot-output-fd slot) +pollin+)
                   (incf nfds))
                 (when (reactor-slot-errors-open slot)
                   (setf (reactor-slot-error-poll-idx slot) nfds)
                   (set-pollfd pollbuf nfds (reactor-slot-error-fd slot) +pollin+)
                   (incf nfds)))))
    nfds))

(defun capture-poll-revents (reactor)
  "Copy `revents' flags from `pollbuf' onto slots and clear poll indices."
  (let ((pollbuf (reactor-pollbuf reactor))
        (slots (reactor-slots reactor)))
    (sb-sys:with-pinned-objects (pollbuf)
      (loop for idx below (length slots)
            for slot = (aref slots idx)
            for s-idx = (reactor-slot-stdin-poll-idx slot)
            for o-idx = (reactor-slot-output-poll-idx slot)
            for e-idx = (reactor-slot-error-poll-idx slot)
            do (setf (reactor-slot-stdin-poll-idx slot) -1
                     (reactor-slot-output-poll-idx slot) -1
                     (reactor-slot-error-poll-idx slot) -1)
               (when (>= s-idx 0)
                 (setf (reactor-slot-stdin-ready slot)
                       (not (zerop (pollfd-revents pollbuf s-idx)))))
               (when (>= o-idx 0)
                 (setf (reactor-slot-output-ready slot)
                       (not (zerop (pollfd-revents pollbuf o-idx)))))
               (when (>= e-idx 0)
                 (setf (reactor-slot-error-ready slot)
                       (not (zerop (pollfd-revents pollbuf e-idx)))))))))

(defun slot-needs-immediate-step-p (slot now)
  "Return true when SLOT can advance without waiting on a kernel file descriptor."
  (ecase (reactor-slot-state slot)
    (:running
     (let ((process (reactor-slot-process slot)))
       (or (slot-cancelled-p slot)
           (and (not (slot-backpressured-p slot))
                (not (sb-ext:process-alive-p process)))
           (and (sb-ext:process-alive-p process)
                (slot-deadline-expired-p slot now)))))
    (:draining
     (slot-cancelled-p slot))
    (:terminating
     (or (not (sb-ext:process-alive-p (reactor-slot-process slot)))
         (and (not (reactor-slot-killed slot))
              (reactor-slot-kill-deadline slot)
              (>= now (reactor-slot-kill-deadline slot)))))))

(defun compute-reactor-timeout-ms (reactor now)
  "Compute the `poll(2)' wait in ms: 0 if immediate, -1 if idle, else min deadline."
  (let ((slots (reactor-slots reactor)))
    (cond ((not (mbox-empty-p (reactor-inbox reactor))) 0)
          ((zerop (length slots)) -1)
          (t
           (let ((min-deadline nil))
             (loop for idx below (length slots)
                   for slot = (aref slots idx)
                   when (slot-needs-immediate-step-p slot now)
                     do (return-from compute-reactor-timeout-ms 0)
                   do (let ((dl (ecase (reactor-slot-state slot)
                                  (:terminating
                                   (and (not (reactor-slot-killed slot))
                                        (reactor-slot-kill-deadline slot)))
                                  (:running
                                   (and (sb-ext:process-alive-p (reactor-slot-process slot))
                                        (reactor-slot-deadline slot)))
                                  (:draining nil))))
                        (when dl
                          (setf min-deadline (if min-deadline (min min-deadline dl) dl)))))
             (compute-poll-timeout-ms t min-deadline))))))

(defun reactor-drain-inbox (reactor now)
  "Consume pending control messages sent to REACTOR."
  (dolist (message (mbox-drain (reactor-inbox reactor)))
    (cond ((eq message :stop)
           (setf (reactor-stopping reactor) t)
           (let ((slots (reactor-slots reactor)))
             (loop for idx below (length slots)
                   for slot = (aref slots idx)
                   unless (eq (reactor-slot-state slot) :terminating)
                     do (unless (slot-begin-terminate reactor slot 'cancelled nil now)
                          (setf (aref slots idx) nil))))
           (let ((slots (reactor-slots reactor))
                 (write 0))
             (loop for idx below (length slots)
                   for slot = (aref slots idx)
                   when slot
                     do (setf (aref slots write) slot)
                        (incf write))
             (setf (fill-pointer slots) write)))
          ((and (consp message) (eq (first message) :start))
           (let ((request (second message)))
             (if (reactor-stopping reactor)
                 (reactor-post-settled reactor request 'cancelled nil)
                 (reactor-start-slot reactor request)))))))

(defun reactor-step-slots (reactor now)
  "Step every active slot in round-robin order and compact retired slots."
  (let* ((slots (reactor-slots reactor))
         (count (length slots))
         (scratch (reactor-scratch reactor)))
    (when (plusp count)
      (let ((start (mod (reactor-rr-cursor reactor) count)))
        (dotimes (offset count)
          (let* ((idx (mod (+ start offset) count))
                 (slot (aref slots idx)))
            (unless (reactor-step-slot reactor slot scratch now)
              (setf (aref slots idx) nil))))
        (let ((write 0))
          (dotimes (idx count)
            (let ((slot (aref slots idx)))
              (when slot
                (setf (aref slots write) slot)
                (incf write))))
          (setf (fill-pointer slots) write
                (reactor-rr-cursor reactor)
                (if (plusp write) (mod (1+ start) write) 0)))))))

(defun reactor-loop (reactor)
  "Event-multiplexed main loop for `P_reactor'."
  (let ((pipe (reactor-pipe reactor))
        (scratch (reactor-scratch reactor))
        (kernel (reactor-kernel reactor)))
    (unwind-protect
         (progn
           (credit-sink-register-room-hook (kernel-outbox kernel)
                                           (lambda () (wakeup-poke pipe)))
           (loop
             (drain-wakeup-pipe pipe scratch)
             (let ((now (get-internal-real-time)))
               (reactor-drain-inbox reactor now)
               (reactor-step-slots reactor now)
               (when (and (reactor-stopping reactor) (zerop (length (reactor-slots reactor))))
                 (mbox-send (kernel-control kernel) '(:reactor-stopped))
                 (return))
               (let* ((nfds (fill-reactor-pollbuf reactor))
                      (timeout-ms (compute-reactor-timeout-ms reactor (get-internal-real-time)))
                      (ready (unix-poll-fds (reactor-pollbuf reactor) nfds timeout-ms)))
                 (when (plusp ready)
                   (capture-poll-revents reactor))))))
      (force-cleanup-slots reactor)
      (close-wakeup-pipe pipe))))

(defun start-exec-reactor (kernel)
  "Start `P_reactor' for KERNEL and return its `reactor-handle'."
  (let* ((inbox (make-mbox :name "lispm-kernel reactor"))
         (pipe (open-wakeup-pipe))
         (reactor (%make-reactor kernel inbox pipe))
         (thread (sb-thread:make-thread #'reactor-loop
                                        :name "lispm-kernel reactor"
                                        :arguments (list reactor))))
    (make-reactor-handle
     thread
     (lambda (request)
       (mbox-send inbox (list :start request))
       (wakeup-poke pipe))
     (lambda ()
       (mbox-send inbox :stop)
       (wakeup-poke pipe)))))

(setf *reactor-starter* #'start-exec-reactor)