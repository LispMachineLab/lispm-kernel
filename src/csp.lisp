;;;; csp.lisp --- Lock-free CSP channels, cancel gates, credit sinks and work groups

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

;;; Core CSP primitives built directly atop SBCL's lock-free `:sb-concurrency'
;;; CAS queues, mailboxes and broadcast gates, without domain mutexes:
;;;
;;;   mbox          multi-producer mailbox channel for fan-in event loops
;;;   cancel-token  broadcast cancellation channel (analogous to Go ctx.Done)
;;;   credit-sink   bounded byte-credit channel with targeted cancel wakeup
;;;   work-group    fixed-size subworker pool with caller work-helping

(in-package #:lispm-kernel/csp)

;;;; Mailboxes (unbounded MPSC/MPMC channels)

(deftype mbox () 'sb-concurrency:mailbox)

(declaim (inline make-mbox mbox-p mbox-send mbox-recv mbox-try-recv
                 mbox-drain mbox-count mbox-empty-p)
         (ftype (function (&key (:name string)) mbox) make-mbox)
         (ftype (function (t) boolean) mbox-p)
         (ftype (function (mbox t) t) mbox-send)
         (ftype (function (mbox &key (:timeout (or null real))) (values t boolean)) mbox-recv)
         (ftype (function (mbox) (values t boolean)) mbox-try-recv)
         (ftype (function (mbox &optional (or null (integer 0))) list) mbox-drain)
         (ftype (function (mbox) (integer 0)) mbox-count)
         (ftype (function (mbox) boolean) mbox-empty-p))

(defun make-mbox (&key (name "csp-mbox"))
  "Create a lock-free CSP mailbox named NAME."
  (sb-concurrency:make-mailbox :name name))

(defun mbox-p (object)
  "Return true when OBJECT is a CSP mailbox."
  (sb-concurrency:mailboxp object))

(defun mbox-send (mbox message)
  "Send MESSAGE to MBOX without blocking."
  (sb-concurrency:send-message mbox message)
  message)

(defun mbox-recv (mbox &key timeout)
  "Receive the oldest message from MBOX, waiting up to TIMEOUT seconds."
  (sb-concurrency:receive-message mbox :timeout timeout))

(defun mbox-try-recv (mbox)
  "Receive one message from MBOX without blocking; second value tells if found."
  (sb-concurrency:receive-message-no-hang mbox))

(defun mbox-drain (mbox &optional count)
  "Drain and return pending messages currently in MBOX (up to COUNT if given)."
  (sb-concurrency:receive-pending-messages mbox count))

(defun mbox-count (mbox)
  "Return the approximate number of messages waiting in MBOX."
  (sb-concurrency:mailbox-count mbox))

(defun mbox-empty-p (mbox)
  "Return true when MBOX holds no pending messages."
  (sb-concurrency:mailbox-empty-p mbox))

;;;; Broadcast cancellation tokens

;;; Invariant: once `hooks' transitions to `:cancelled', `gate' is open and
;;; any subsequent `register-cancel-hook' runs its callback immediately.
(defstruct (cancel-token (:constructor make-cancel-token (&key name)) (:copier nil))
  "A one-shot broadcast cancellation channel."
  (gate (sb-concurrency:make-gate :name (or name "cancel-token") :open nil)
   :type sb-concurrency:gate :read-only t)
  (hooks '() :type (or list (eql :cancelled))))

(declaim (inline cancelled-p)
         (ftype (function (cancel-token) boolean) cancelled-p cancel!)
         (ftype (function (cancel-token &key (:timeout (or null real))) boolean) await-cancel)
         (ftype (function (cancel-token function) boolean) register-cancel-hook))

(defun cancelled-p (token)
  "Return true when TOKEN has been cancelled."
  (or (eq (cancel-token-hooks token) :cancelled)
      (and (sb-concurrency:gate-open-p (cancel-token-gate token)) t)))

(defun cancel! (token)
  "Open TOKEN's cancellation gate and invoke registered hooks at most once.
Return true when this call performed the transition, nil if already cancelled."
  ;; Open the gate before transitioning `hooks' so any observer woken by a hook
  ;; or `await-cancel' sees `(cancelled-p token)' as true immediately.
  (sb-concurrency:open-gate (cancel-token-gate token))
  (loop
    (let ((old (cancel-token-hooks token)))
      (when (eq old :cancelled)
        (return nil))
      (when (eq old (sb-ext:compare-and-swap (cancel-token-hooks token) old :cancelled))
        (dolist (hook (reverse old))
          (handler-case (funcall hook)
            (serious-condition () nil)))
        (return t)))))

(defun await-cancel (token &key timeout)
  "Wait until TOKEN is cancelled or TIMEOUT seconds elapse.
Return true when TOKEN was cancelled, nil on timeout."
  (and (sb-concurrency:wait-on-gate (cancel-token-gate token) :timeout timeout) t))

(defun register-cancel-hook (token callback)
  "Register zero-argument CALLBACK to run when TOKEN is cancelled.
If TOKEN is already cancelled, invoke CALLBACK immediately and return nil;
otherwise return true."
  (loop
    (let ((old (cancel-token-hooks token)))
      (when (eq old :cancelled)
        (handler-case (funcall callback)
          (serious-condition () nil))
        (return nil))
      (let ((next (cons callback old)))
        (when (eq old (sb-ext:compare-and-swap (cancel-token-hooks token) old next))
          (return t))))))

;;;; Credit-bounded outbox sink

(defstruct (stream-credit (:constructor make-stream-credit (&key (limit (* 256 1024))))
                          (:copier nil))
  "Lock-free per-stream byte budget isolating one noisy stream from sibling streams."
  (limit (* 256 1024) :type sb-ext:word :read-only t)
  (waiting 0 :type sb-ext:word))

(defstruct (credit-sink (:constructor make-credit-sink (&key (limit (* 4 1024 1024))))
                        (:copier nil))
  "A FIFO message channel where control messages pass freely while data chunks
respect a byte credit budget and wake individually on cancellation."
  (wire (make-mbox :name "credit-sink wire") :type mbox :read-only t)
  (room-waiters (sb-concurrency:make-queue :name "credit-sink waiters")
   :type sb-concurrency:queue :read-only t)
  (room-hooks '() :type list)
  (limit 0 :type sb-ext:word)
  (waiting 0 :type sb-ext:word)
  (peak 0 :type sb-ext:word)
  (closed nil :type boolean))

(declaim (ftype (function (credit-sink) boolean) credit-sink-closed-p)
         (ftype (function (credit-sink function) boolean) credit-sink-register-room-hook)
         (ftype (function (credit-sink string) boolean) credit-sink-put-control)
         (ftype (function (credit-sink string &key (:token (or null cancel-token))
                                                   (:limit (or null (integer 0))))
                          boolean)
                credit-sink-put-chunk)
         (ftype (function (credit-sink string &key (:token (or null cancel-token))
                                                   (:limit (or null (integer 0)))
                                                   (:stream-credit (or null stream-credit)))
                          (member :sent :full :cancelled :closed))
                credit-sink-try-put-chunk)
         (ftype (function (credit-sink) list) credit-sink-take)
         (ftype (function (credit-sink) credit-sink) credit-sink-close))

(defun credit-sink-closed-p (sink)
  "Return true when SINK has been closed."
  (credit-sink-closed sink))

(defun credit-sink-register-room-hook (sink hook)
  "Register zero-argument HOOK to run when SINK frees credit or closes.
Invoke HOOK immediately and return nil when SINK is already closed."
  (check-type hook function)
  (loop
    (when (credit-sink-closed sink)
      (handler-case (funcall hook)
        (serious-condition () nil))
      (return nil))
    (let* ((old (credit-sink-room-hooks sink))
           (next (cons hook old)))
      (when (eq old (sb-ext:compare-and-swap (credit-sink-room-hooks sink) old next))
        (when (credit-sink-closed sink)
          (handler-case (funcall hook)
            (serious-condition () nil)))
        (return t)))))

(defun update-peak-waiting (sink current)
  "Monotonically raise SINK's peak queued byte count to at least CURRENT."
  (declare (type credit-sink sink) (type sb-ext:word current))
  (loop
    (let ((old (credit-sink-peak sink)))
      (when (or (>= old current)
                (eql old (sb-ext:compare-and-swap (credit-sink-peak sink) old current)))
        (return)))))

(defun try-acquire-stream-credit (sc bytes)
  "Atomically reserve BYTES in per-stream budget SC when room allows."
  (declare (type stream-credit sc) (type sb-ext:word bytes))
  (let ((limit (stream-credit-limit sc)))
    (loop
      (let ((current (stream-credit-waiting sc)))
        (when (and (plusp current) (> (+ current bytes) limit))
          (return nil))
        (when (eql current (sb-ext:compare-and-swap (stream-credit-waiting sc)
                                                  current (+ current bytes)))
          (return t))))))

(defun try-acquire-credit (sink bytes limit)
  "Atomically reserve BYTES against LIMIT in SINK when room allows."
  (declare (type credit-sink sink) (type sb-ext:word bytes limit))
  (loop
    (let ((current (credit-sink-waiting sink)))
      (when (and (plusp current) (> (+ current bytes) limit))
        (return nil))
      (let ((next (+ current bytes)))
        (when (eql current (sb-ext:compare-and-swap (credit-sink-waiting sink) current next))
          (update-peak-waiting sink next)
          (return t))))))

(defun wake-room-waiters (sink)
  "Wake all senders and room hooks currently waiting on SINK."
  (let ((queue (credit-sink-room-waiters sink)))
    (loop
      (multiple-value-bind (gate found) (sb-concurrency:dequeue queue)
        (unless found (return))
        (sb-concurrency:open-gate gate))))
  (dolist (hook (credit-sink-room-hooks sink))
    (handler-case (funcall hook)
      (serious-condition () nil))))

(defun credit-sink-put-control (sink string)
  "Send control or final message STRING to SINK without waiting for credit.
Return nil when SINK is already closed."
  (if (credit-sink-closed sink)
      nil
      (progn
        (mbox-send (credit-sink-wire sink) (cons string nil))
        t)))

(defun release-chunk-credit (sink bytes stream-credit)
  "Return reserved BYTES to SINK and STREAM-CREDIT after an aborted send."
  (declare (type credit-sink sink)
           (type sb-ext:word bytes)
           (type (or null stream-credit) stream-credit))
  (sb-ext:atomic-decf (credit-sink-waiting sink) bytes)
  (when stream-credit
    (sb-ext:atomic-decf (stream-credit-waiting stream-credit) bytes))
  (wake-room-waiters sink))

(defun credit-sink-try-put-chunk (sink string &key token limit stream-credit)
  "Send chunk STRING to SINK without blocking.
Return `:sent' when accepted, `:full' when global or STREAM-CREDIT budget is
exhausted, `:cancelled' when TOKEN fired, or `:closed' when SINK is closed."
  (when (and token (cancelled-p token))
    (return-from credit-sink-try-put-chunk :cancelled))
  (when (credit-sink-closed sink)
    (return-from credit-sink-try-put-chunk :closed))
  (let ((bytes (length string))
        (effective-limit (max 0 (or limit (credit-sink-limit sink)))))
    (when (and stream-credit (not (try-acquire-stream-credit stream-credit bytes)))
      (return-from credit-sink-try-put-chunk :full))
    (unless (try-acquire-credit sink bytes effective-limit)
      (when stream-credit
        (sb-ext:atomic-decf (stream-credit-waiting stream-credit) bytes))
      (return-from credit-sink-try-put-chunk :full))
    (when (and token (cancelled-p token))
      (release-chunk-credit sink bytes stream-credit)
      (return-from credit-sink-try-put-chunk :cancelled))
    (when (credit-sink-closed sink)
      (release-chunk-credit sink bytes stream-credit)
      (return-from credit-sink-try-put-chunk :closed))
    (mbox-send (credit-sink-wire sink)
               (cons string (if stream-credit (cons bytes stream-credit) bytes)))
    :sent))

(defun credit-sink-put-chunk (sink string &key token limit)
  "Send chunk STRING to SINK, waiting when queued chunks exceed LIMIT.
When TOKEN is cancelled while waiting, nothing is queued and nil is returned."
  (let ((bytes (length string))
        (effective-limit (max 0 (or limit (credit-sink-limit sink))))
        (active-gate nil)
        (hook-registered nil))
    (unwind-protect
         (loop
           (when (and token (cancelled-p token))
             (return nil))
           (when (or (credit-sink-closed sink)
                     (try-acquire-credit sink bytes effective-limit))
             (when (and token (cancelled-p token))
               (unless (credit-sink-closed sink)
                 (sb-ext:atomic-decf (credit-sink-waiting sink) bytes)
                 (wake-room-waiters sink))
               (return nil))
             (unless (credit-sink-closed sink)
               (mbox-send (credit-sink-wire sink) (cons string bytes)))
             (return t))
           (let ((gate (sb-concurrency:make-gate :name "chunk-credit" :open nil)))
             (setf active-gate gate)
             (when (and token (not hook-registered))
               (setf hook-registered t)
               (register-cancel-hook
                token
                (lambda ()
                  (let ((current active-gate))
                    (when current
                      (sb-concurrency:open-gate current))))))
             (when (and token (cancelled-p token))
               (sb-concurrency:open-gate gate))
             (sb-concurrency:enqueue gate (credit-sink-room-waiters sink))
             ;; Re-check after enqueue so a concurrent drain cannot miss this gate.
             (unless (or (and token (cancelled-p token))
                         (credit-sink-closed sink)
                         (let ((cur (credit-sink-waiting sink)))
                           (or (zerop cur) (<= (+ cur bytes) effective-limit))))
               (sb-concurrency:wait-on-gate gate :timeout 0.05))))
      (setf active-gate nil))))

(defun release-entry-credits (sink entries)
  "Credit back global and per-stream byte budgets for drained ENTRIES in SINK."
  (let ((freed 0))
    (declare (type sb-ext:word freed))
    (dolist (entry entries)
      (let ((meta (cdr entry)))
        (cond ((integerp meta)
               (incf freed (the sb-ext:word meta)))
              ((consp meta)
               (let ((bytes (the sb-ext:word (car meta)))
                     (sc (the stream-credit (cdr meta))))
                 (incf freed bytes)
                 (sb-ext:atomic-decf (stream-credit-waiting sc) bytes))))))
    (when (plusp freed)
      (sb-ext:atomic-decf (credit-sink-waiting sink) freed)
      (wake-room-waiters sink))))

(defun credit-sink-take (sink)
  "Block until at least one message arrives in SINK, then drain and return a
batch of strings in FIFO order.  Return nil once SINK is closed and empty."
  (let ((wire (credit-sink-wire sink)))
    (loop
      (let* ((first (mbox-recv wire))
             (rest (mbox-drain wire))
             (entries (cons first rest))
             (messages '())
             (credit-entries '())
             (saw-eof nil))
        (dolist (entry entries)
          (if (eq entry :eof)
              (setf saw-eof t)
              (progn
                (push (car entry) messages)
                (when (cdr entry)
                  (push entry credit-entries)))))
        (when credit-entries
          (release-entry-credits sink credit-entries))
        (when messages
          (when saw-eof
            (mbox-send wire :eof))
          (return (nreverse messages)))
        (when (or saw-eof (credit-sink-closed sink))
          (return nil))))))

(defun credit-sink-close (sink)
  "Mark SINK closed so its consumer exits after draining queued messages."
  (setf (credit-sink-closed sink) t)
  (mbox-send (credit-sink-wire sink) :eof)
  (wake-room-waiters sink)
  sink)

;;;; Fixed-size work-helping parallel pool

(defstruct (batch (:constructor make-batch (items results count function token context))
                  (:copier nil))
  (items #() :type simple-vector :read-only t)
  (results #() :type simple-vector :read-only t)
  (count 0 :type sb-ext:word :read-only t)
  (function #'identity :type function :read-only t)
  (token nil :type (or null cancel-token) :read-only t)
  (context #'funcall :type function :read-only t)
  (next-index 0 :type sb-ext:word)
  (in-flight 0 :type sb-ext:word)
  (failure nil)
  (done (sb-concurrency:make-gate :name "batch-done" :open nil)
   :type sb-concurrency:gate :read-only t))

(defun batch-aborted-p (batch)
  "Return true when BATCH recorded an error or its cancel token fired."
  (or (not (null (batch-failure batch)))
      (let ((token (batch-token batch)))
        (and token (cancelled-p token)))))

(defun record-batch-failure (batch condition)
  "Atomically store the first serious CONDITION raised within BATCH."
  (loop
    (let ((old (batch-failure batch)))
      (when (or old (eq nil (sb-ext:compare-and-swap (batch-failure batch) nil condition)))
        (return)))))

(defun run-batch-participant (batch)
  "Consume unclaimed items from BATCH until exhausted, cancelled, or failed."
  (let ((count (batch-count batch))
        (items (batch-items batch))
        (results (batch-results batch))
        (fn (batch-function batch)))
    (when (or (>= (batch-next-index batch) count) (batch-aborted-p batch))
      (when (zerop (batch-in-flight batch))
        (sb-concurrency:open-gate (batch-done batch)))
      (return-from run-batch-participant nil))
    (funcall (batch-context batch)
             (lambda ()
               (loop
                 (when (or (>= (batch-next-index batch) count) (batch-aborted-p batch))
                   (when (zerop (batch-in-flight batch))
                     (sb-concurrency:open-gate (batch-done batch)))
                   (return))
                 (sb-ext:atomic-incf (batch-in-flight batch))
                 (unwind-protect
                      (let ((index (sb-ext:atomic-incf (batch-next-index batch))))
                        (when (and (< index count) (not (batch-aborted-p batch)))
                          (handler-case
                              (setf (svref results index) (funcall fn (svref items index)))
                            (serious-condition (condition)
                              (record-batch-failure batch condition)))))
                   (let ((prev (sb-ext:atomic-decf (batch-in-flight batch))))
                     (when (and (= prev 1)
                                (or (>= (batch-next-index batch) count)
                                    (batch-aborted-p batch)))
                       (sb-concurrency:open-gate (batch-done batch))))))))))

(defstruct (work-group (:constructor %make-work-group (mbox size)) (:copier nil))
  "A fixed pool of persistent CSP subworker threads."
  (mbox nil :type mbox :read-only t)
  (size 0 :type (integer 0) :read-only t)
  (threads '() :type list))

(declaim (ftype (function (&key (:workers (integer 0)) (:name string)) work-group)
                make-work-group)
         (ftype (function (work-group &key (:timeout (or null real))) work-group)
                stop-work-group)
         (ftype (function ((or null work-group) function sequence
                           &key (:threads integer)
                                (:token (or null cancel-token))
                                (:context function))
                          list)
                work-group-map))

(defun subworker-loop (mbox)
  "Persistent subworker loop consuming `batch' items from MBOX until `:stop'."
  (loop for message = (mbox-recv mbox)
        until (eq message :stop)
        do (when (batch-p message)
             (run-batch-participant message))))

(defun make-work-group (&key (workers 3) (name "lispm-kernel subworker"))
  "Start a fixed work-group with WORKERS persistent subworker threads."
  (let* ((mbox (make-mbox :name name))
         (wg (%make-work-group mbox workers)))
    (setf (work-group-threads wg)
          (loop for idx from 1 to workers
                collect (sb-thread:make-thread
                         #'subworker-loop
                         :name (format nil "~A ~D" name idx)
                         :arguments (list mbox))))
    wg))

(defun stop-work-group (wg &key (timeout 5))
  "Stop all subworker threads in WG cleanly."
  (let ((threads (work-group-threads wg)))
    (setf (work-group-threads wg) '())
    (dolist (_ threads)
      (declare (ignore _))
      (mbox-send (work-group-mbox wg) :stop))
    (dolist (thread threads)
      (sb-thread:join-thread thread :default nil :timeout timeout))
    wg))

(defun work-group-map (wg function list &key (threads 4) token (context #'funcall))
  "Apply FUNCTION across LIST using WG plus the calling thread (work-helping).
Never spawns transient OS threads; propagates errors and respects TOKEN."
  (let* ((items (coerce list 'simple-vector))
         (count (length items)))
    (cond ((zerop count) '())
          ((or (<= threads 1) (= count 1) (null wg) (zerop (work-group-size wg)))
           (let ((results (make-array count :initial-element nil)))
             (funcall context
                      (lambda ()
                        (loop for idx below count
                              until (and token (cancelled-p token))
                              do (setf (svref results idx)
                                       (funcall function (svref items idx))))))
             (coerce results 'list)))
          (t
           (let* ((results (make-array count :initial-element nil))
                  (batch (make-batch items results count function token context))
                  (helpers (min (1- threads) (1- count) (work-group-size wg))))
             (loop repeat helpers
                   do (mbox-send (work-group-mbox wg) batch))
             (run-batch-participant batch)
             (sb-concurrency:wait-on-gate (batch-done batch))
             (when (batch-failure batch)
               (error (batch-failure batch)))
             (coerce results 'list))))))
