;;; lispm-kernel.el --- LispM's kernel, a Lisp beside Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-kernel
;; Version: 0.3.0
;; Package-Requires: ((emacs "30.1"))
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is not part of GNU Emacs.

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

;;; Commentary:

;; The kernel is a Common Lisp program, SBCL's runtime and the kernel's
;; core in one executable, that does work Emacs should not wait on, on
;; threads of its own.  Emacs runs it as a process and the two talk in
;; S-expressions, one per line:
;;
;;   Emacs   (submit ID JOB INPUT :owner O :generation G :priority P)
;;           (cancel ID)  (supersede OWNER GENERATION)  (stats)
;;   kernel  (hello :protocol 1 ...)
;;           (chunk ID DATA) ... (done ID STATUS VALUE)
;;
;; `lispm-kernel-start' runs a kernel and returns its runtime;
;; `lispm-kernel-submit' asks it for a job, and the callback hears each
;; chunk and then, once, how the request ended: `success', `failed',
;; `cancelled' or `rejected' as the kernel says, `timeout' after
;; `lispm-kernel-request-timeout', or `lost' when the kernel exits first.
;; An owner's requests of an older generation than its current one are
;; cancelled and their callbacks hear nothing more.
;;
;; What the kernel writes wakes Emacs as any process output does, and is
;; taken in a slice at a time, `lispm-kernel-slice-seconds' long, giving
;; way to typing: by a timer, or by `lispm-kernel-scheduler', which
;; lispm-kernel-broker.el sets to LispM Desktop's frame clock.  Callbacks
;; run on Emacs's thread and cannot be preempted; they should be short.
;; The program comes from lispm-kernel-program.el.

;;; Code:

(require 'cl-lib)

(defconst lispm-kernel-protocol 1
  "The protocol this Lisp speaks; a kernel saying another is refused.")

(defgroup lispm-kernel nil
  "LispM's kernel: background work done in a Lisp of its own."
  :group 'applications)

(defcustom lispm-kernel-slice-seconds 0.003
  "Seconds Emacs spends taking in the kernel's messages at a time.
It gives way to typing after them; one callback can take longer."
  :type 'number)

(defcustom lispm-kernel-request-timeout 60
  "Seconds a request may take before its callback hears `timeout'.
The kernel is asked to cancel it.  Nil waits for ever."
  :type '(choice (const :tag "Never" nil) number))

(defvar lispm-kernel-scheduler nil
  "Nil, or a function that schedules the taking in of a runtime's messages.
It is called with the runtime and returns non-nil when it took it; else a
timer does.  It calls `lispm-kernel-dispatch' later, with
`lispm-kernel-slice-seconds' bound to its budget.")

(defvar lispm-kernel--runtimes nil
  "Runtimes not yet stopped, so unloading can stop them.")

(cl-defstruct (lispm-kernel-runtime (:constructor lispm-kernel--make-runtime)
                                    (:copier nil))
  "A kernel process and what Emacs keeps of its requests."
  process stderr program hello
  (started (float-time))
  (next-id 0)
  ;; Lines received and not yet handled: INCOMING newest first, READY oldest first.
  (incoming nil) (ready nil)
  ;; Pieces of the line being received, newest first.
  (partial nil)
  timer expiry-timer
  (closed nil) (exited nil) exited-at (dispatching nil)
  (overruns 0) last-error
  (requests (make-hash-table :test #'eql))
  (generations (make-hash-table :test #'eql))
  ;; Callbacks waiting for (stats ...) and (pong ...), oldest first.
  (waiters nil))

(cl-defstruct (lispm-kernel--pending (:constructor lispm-kernel--pending) (:copier nil))
  "A request waiting for its final word."
  callback owner generation deadline)

;;;; Starting and stopping

(defun lispm-kernel-start (program)
  "Run the kernel PROGRAM and return its runtime.
Its standard error goes to the buffer \" *lispm-kernel*\"."
  (unless (and (stringp program) (file-executable-p program))
    (error "No kernel program to run: %S" program))
  (let* ((runtime (lispm-kernel--make-runtime :program program))
         (default-directory (expand-file-name "~/"))
         (buffer (get-buffer-create " *lispm-kernel*"))
         (stderr (make-pipe-process :name "lispm-kernel stderr" :buffer buffer :noquery t
                                    :coding 'utf-8-unix
                                    :filter #'lispm-kernel--stderr-filter)))
    (setf (lispm-kernel-runtime-stderr runtime) stderr
          (lispm-kernel-runtime-process runtime)
          (make-process :name "lispm-kernel" :command (list program) :connection-type 'pipe
                        :noquery t :coding 'utf-8-unix :stderr stderr
                        :filter (lambda (_process string) (lispm-kernel--filter runtime string))
                        :sentinel (lambda (process _event) (lispm-kernel--sentinel runtime process))))
    (push runtime lispm-kernel--runtimes)
    runtime))

(defun lispm-kernel--stderr-filter (process string)
  "Keep the last 64 KiB of what the kernel PROCESS says on its standard error."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert string)
        (when (> (buffer-size) 65536)
          (delete-region (point-min) (- (point-max) 65536)))))))

(defun lispm-kernel-live-p (runtime)
  "Return non-nil while RUNTIME's kernel runs and takes requests."
  (and runtime
       (not (lispm-kernel-runtime-closed runtime))
       (not (lispm-kernel-runtime-exited runtime))
       (process-live-p (lispm-kernel-runtime-process runtime))
       t))

(defun lispm-kernel-why-not-running (runtime)
  "Return why RUNTIME's kernel does not run, a sentence, or nil while it does.
A kernel whose exit Emacs has not heard of yet says so from its process."
  (unless (lispm-kernel-live-p runtime)
    (or (lispm-kernel-runtime-last-error runtime)
        (lispm-kernel-runtime-exited runtime)
        (and (lispm-kernel-runtime-closed runtime) "the kernel was stopped")
        (let ((process (lispm-kernel-runtime-process runtime)))
          (format "the kernel exited (%s %s)" (process-status process) (process-exit-status process))))))

(defun lispm-kernel-pending-p (runtime)
  "Return non-nil while RUNTIME has requests waiting or messages to take in."
  (and (not (lispm-kernel-runtime-closed runtime))
       (or (> (hash-table-count (lispm-kernel-runtime-requests runtime)) 0)
           (lispm-kernel-runtime-waiters runtime)
           (lispm-kernel--lines-p runtime))
       t))

(defun lispm-kernel--cancel-timers (runtime)
  (dolist (timer (list (lispm-kernel-runtime-timer runtime) (lispm-kernel-runtime-expiry-timer runtime)))
    (when timer (cancel-timer timer)))
  (setf (lispm-kernel-runtime-timer runtime) nil
        (lispm-kernel-runtime-expiry-timer runtime) nil))

(defun lispm-kernel-stop (runtime)
  "Stop RUNTIME's kernel at once, without waiting for its work.
Callbacks waiting hear nothing more."
  (unless (lispm-kernel-runtime-closed runtime)
    (setf (lispm-kernel-runtime-closed runtime) t)
    (setq lispm-kernel--runtimes (delq runtime lispm-kernel--runtimes))
    (lispm-kernel--cancel-timers runtime)
    (clrhash (lispm-kernel-runtime-requests runtime))
    (setf (lispm-kernel-runtime-waiters runtime) nil
          (lispm-kernel-runtime-incoming runtime) nil
          (lispm-kernel-runtime-ready runtime) nil
          (lispm-kernel-runtime-partial runtime) nil)
    (dolist (process (list (lispm-kernel-runtime-process runtime) (lispm-kernel-runtime-stderr runtime)))
      (when (process-live-p process)
        (delete-process process)))))

(defun lispm-kernel-unload-function ()
  "Stop every kernel before `unload-feature' removes this library."
  (mapc #'lispm-kernel-stop (copy-sequence lispm-kernel--runtimes))
  nil)

;;;; Sending

(defun lispm-kernel--wire-symbol-p (symbol)
  "Return non-nil when SYMBOL's name reads back as that symbol in the
kernel: ASCII letters, digits and _/*+<>=!?-, a keyword's after its
colon, not starting with ? and no number: 1+ and e1 are none."
  (let ((name (string-remove-prefix ":" (symbol-name symbol))))
    (and (string-match-p "\\`[a-zA-Z0-9_/*+<>=!-][a-zA-Z0-9_/*+<>=!?-]*\\'" name)
         (not (and (string-match-p "[0-9]" name)
                   (string-match-p "\\`[-+.eE0-9]+\\'" name))))))

(defun lispm-kernel--wire-p (datum &optional depth)
  "Return non-nil when DATUM can go to the kernel: integers, strings,
plain symbols, lists and vectors of them, nested at most 63 deep, so
that the message holding it is at most 64 deep."
  (let ((depth (or depth 0)))
    (and (<= depth 63)
         (cond ((or (null datum) (eq datum t) (integerp datum) (stringp datum)) t)
               ((symbolp datum) (lispm-kernel--wire-symbol-p datum))
               ((consp datum)
                (and (proper-list-p datum)
                     (cl-every (lambda (item) (lispm-kernel--wire-p item (1+ depth))) datum)))
               ((vectorp datum)
                (cl-every (lambda (item) (lispm-kernel--wire-p item (1+ depth))) datum))))))

(defun lispm-kernel--plain (datum)
  "Return DATUM with its strings' text properties left out, which the
kernel cannot read."
  (cond ((stringp datum) (substring-no-properties datum))
        ((proper-list-p datum) (mapcar #'lispm-kernel--plain datum))
        ((and (vectorp datum) (not (stringp datum))) (vconcat (mapcar #'lispm-kernel--plain datum)))
        (t datum)))

(defun lispm-kernel--send (runtime form)
  "Send FORM to RUNTIME's kernel, on one line."
  (let ((print-escape-newlines t)
        (print-escape-control-characters t)
        (print-escape-nonascii nil)
        (print-escape-multibyte nil)
        (print-length nil)
        (print-level nil)
        (print-circle nil)
        ;; (quote x) as it is, not 'x, which the kernel does not read.
        (print-quoted nil)
        (print-integers-as-characters nil))
    (process-send-string (lispm-kernel-runtime-process runtime)
                         (concat (prin1-to-string form) "\n"))))

(cl-defun lispm-kernel-submit (runtime job input &key (owner 0) (generation 0) (priority 0)
                                       on-result (timeout lispm-kernel-request-timeout))
  "Ask RUNTIME's kernel for JOB, a symbol, with INPUT; return the request's id.
INPUT is made of integers, strings, plain symbols, lists and vectors.
ON-RESULT is called with KIND and VALUE for each `chunk' the job emits,
then once with how the request ended: `success' and its result,
`failed' and why, `cancelled', or `rejected' and why (`capacity',
`stale', `unknown-job'); `timeout' when it takes longer than TIMEOUT
seconds, the kernel being asked to cancel it; `lost' when the kernel
exits first.  OWNER's requests of a GENERATION older than one submitted
or superseded later are cancelled, and their callbacks hear nothing
more.  Of PRIORITY, -100 to 100, a higher one runs first."
  (unless (lispm-kernel-live-p runtime)
    (error "The kernel is not running"))
  (setq input (lispm-kernel--plain input))
  (unless (and (symbolp job) (lispm-kernel--wire-p job) (lispm-kernel--wire-p input))
    (error "Only integers, strings, symbols, lists and vectors go to the kernel: %S" input))
  (unless (and (integerp owner) (integerp generation) (integerp priority) (<= -100 priority 100))
    (error "Owner and generation are integers, priority one from -100 to 100"))
  (let ((generations (lispm-kernel-runtime-generations runtime)))
    (when (< generation (gethash owner generations 0))
      (error "Generation %s of owner %s is older than its current one" generation owner))
    (puthash owner generation generations))
  (let ((id (cl-incf (lispm-kernel-runtime-next-id runtime))))
    (puthash id (lispm-kernel--pending :callback on-result :owner owner :generation generation
                                       :deadline (and timeout (+ (float-time) timeout)))
             (lispm-kernel-runtime-requests runtime))
    (condition-case error
        (lispm-kernel--send runtime `(submit ,id ,job ,input :owner ,owner :generation ,generation
                                             :priority ,priority))
      ;; The kernel went away meanwhile: the request was never made.
      (error (remhash id (lispm-kernel-runtime-requests runtime))
             (signal (car error) (cdr error))))
    (when timeout
      (lispm-kernel--arm-expiry runtime))
    id))

(defun lispm-kernel-cancel (runtime id)
  "Ask RUNTIME's kernel to cancel request ID; its callback hears `cancelled'."
  (when (lispm-kernel-live-p runtime)
    (lispm-kernel--send runtime `(cancel ,id))))

(defun lispm-kernel-supersede (runtime owner generation)
  "Make GENERATION OWNER's current one in RUNTIME: its older requests are
cancelled, and their callbacks hear nothing more."
  (let ((generations (lispm-kernel-runtime-generations runtime)))
    (when (< generation (gethash owner generations 0))
      (error "Generation %s of owner %s is older than its current one" generation owner))
    (puthash owner generation generations))
  (when (lispm-kernel-live-p runtime)
    (lispm-kernel--send runtime `(supersede ,owner ,generation))))

(defun lispm-kernel--ask (runtime kind form callback)
  "Send FORM, to which RUNTIME's kernel answers with a message headed by
KIND; CALLBACK gets the rest of that message."
  (when (lispm-kernel-live-p runtime)
    (setf (lispm-kernel-runtime-waiters runtime)
          (append (lispm-kernel-runtime-waiters runtime) (list (cons kind callback))))
    (lispm-kernel--send runtime form)
    t))

(defun lispm-kernel-stats (runtime callback)
  "Call CALLBACK with a plist of what RUNTIME's kernel holds and has done."
  (lispm-kernel--ask runtime 'stats '(stats) (lambda (arguments) (funcall callback (car arguments)))))

(defun lispm-kernel-ping (runtime callback &rest data)
  "Call CALLBACK with DATA once RUNTIME's kernel has echoed it back."
  (lispm-kernel--ask runtime 'pong `(ping ,@data) callback))

(defun lispm-kernel-clear-caches (runtime)
  "Make RUNTIME's kernel forget what its jobs keep between requests."
  (when (lispm-kernel-live-p runtime)
    (lispm-kernel--send runtime '(clear-caches))))

;;;; Receiving

(defun lispm-kernel--filter (runtime string)
  "Queue the lines of STRING, output of RUNTIME's kernel, and schedule them."
  (unless (lispm-kernel-runtime-closed runtime)
    (let ((start 0) newline)
      (while (setq newline (string-search "\n" string start))
        (let ((piece (substring string start newline)))
          (push (if (lispm-kernel-runtime-partial runtime)
                    (prog1 (apply #'concat (nreverse (cons piece (lispm-kernel-runtime-partial runtime))))
                      (setf (lispm-kernel-runtime-partial runtime) nil))
                  piece)
                (lispm-kernel-runtime-incoming runtime)))
        (setq start (1+ newline)))
      (when (< start (length string))
        (push (substring string start) (lispm-kernel-runtime-partial runtime))))
    (lispm-kernel--schedule runtime)))

(defun lispm-kernel--sentinel (runtime process)
  "Note that RUNTIME's kernel PROCESS has exited."
  (unless (or (process-live-p process) (lispm-kernel-runtime-closed runtime))
    (setf (lispm-kernel-runtime-exited runtime)
          (format "the kernel exited (%s %s)" (process-status process) (process-exit-status process))
          (lispm-kernel-runtime-exited-at runtime) (float-time))
    (lispm-kernel--schedule runtime)))

(defun lispm-kernel--tick (runtime)
  (setf (lispm-kernel-runtime-timer runtime) nil)
  (lispm-kernel-dispatch runtime))

(defun lispm-kernel--schedule (runtime)
  "Have RUNTIME's messages taken in soon, by `lispm-kernel-scheduler' or a timer."
  (unless (or (lispm-kernel-runtime-closed runtime)
              (and lispm-kernel-scheduler (funcall lispm-kernel-scheduler runtime))
              (lispm-kernel-runtime-timer runtime))
    (setf (lispm-kernel-runtime-timer runtime)
          (run-at-time 0 nil #'lispm-kernel--tick runtime))))

(defun lispm-kernel--next-line (runtime)
  "Return the oldest line of RUNTIME not handled yet, removing it, or nil."
  (unless (lispm-kernel-runtime-ready runtime)
    (setf (lispm-kernel-runtime-ready runtime) (nreverse (lispm-kernel-runtime-incoming runtime))
          (lispm-kernel-runtime-incoming runtime) nil))
  (pop (lispm-kernel-runtime-ready runtime)))

(defun lispm-kernel--lines-p (runtime)
  (or (lispm-kernel-runtime-ready runtime) (lispm-kernel-runtime-incoming runtime)))

(defun lispm-kernel-dispatch (runtime)
  "Take in RUNTIME's messages for `lispm-kernel-slice-seconds', at least one,
giving way to typing; schedule the rest.  It does not run inside itself."
  (unless (or (lispm-kernel-runtime-closed runtime) (lispm-kernel-runtime-dispatching runtime))
    (setf (lispm-kernel-runtime-dispatching runtime) t)
    (unwind-protect
        (let ((deadline (+ (float-time) (max 0 lispm-kernel-slice-seconds)))
              (first t))
          (while (and (not (lispm-kernel-runtime-closed runtime))
                      (lispm-kernel--lines-p runtime)
                      (or first (and (< (float-time) deadline) (not (input-pending-p)))))
            (setq first nil)
            (lispm-kernel--handle runtime (lispm-kernel--next-line runtime)))
          (unless (lispm-kernel-runtime-closed runtime)
            (lispm-kernel--expire runtime)
            (when (and (lispm-kernel-runtime-exited runtime) (not (lispm-kernel--lines-p runtime)))
              (lispm-kernel--abandon runtime))))
      (setf (lispm-kernel-runtime-dispatching runtime) nil)
      (when (and (not (lispm-kernel-runtime-closed runtime)) (lispm-kernel--lines-p runtime))
        (lispm-kernel--schedule runtime)))))

(defun lispm-kernel--handle (runtime line)
  "Act on LINE, one message of RUNTIME's kernel."
  (pcase (condition-case error
             (car (read-from-string line))
           (error (list 'unreadable (error-message-string error))))
    (`(hello . ,properties)
     (setf (lispm-kernel-runtime-hello runtime) properties)
     (unless (eql (plist-get properties :protocol) lispm-kernel-protocol)
       (setf (lispm-kernel-runtime-last-error runtime)
             (format "the kernel speaks protocol %S, not %S"
                     (plist-get properties :protocol) lispm-kernel-protocol))
       (lispm-kernel--abandon runtime)))
    (`(chunk ,id ,data) (lispm-kernel--deliver runtime id 'chunk data nil))
    (`(done ,id ,status ,value) (lispm-kernel--deliver runtime id status value t))
    (`(,(and kind (or 'stats 'pong)) . ,arguments)
     (let ((waiter (assq kind (lispm-kernel-runtime-waiters runtime))))
       (when waiter
         (setf (lispm-kernel-runtime-waiters runtime) (delq waiter (lispm-kernel-runtime-waiters runtime)))
         (lispm-kernel--call runtime (cdr waiter) arguments))))
    (message (setf (lispm-kernel-runtime-last-error runtime) message))))

(defun lispm-kernel--call (runtime function &rest arguments)
  "Call FUNCTION with ARGUMENTS, keeping an error it signals in RUNTIME."
  (when function
    (let ((started (float-time)))
      (condition-case error
          (apply function arguments)
        (error (setf (lispm-kernel-runtime-last-error runtime) error)))
      (when (> (- (float-time) started) lispm-kernel-slice-seconds)
        (cl-incf (lispm-kernel-runtime-overruns runtime))))))

(defun lispm-kernel--current-p (runtime pending)
  "Return non-nil when PENDING's generation is its owner's current one."
  (= (lispm-kernel--pending-generation pending)
     (gethash (lispm-kernel--pending-owner pending) (lispm-kernel-runtime-generations runtime) 0)))

(defun lispm-kernel--deliver (runtime id kind value final)
  "Give request ID's callback KIND and VALUE; FINAL ends the request."
  (let ((pending (gethash id (lispm-kernel-runtime-requests runtime))))
    (when pending
      (when final
        (remhash id (lispm-kernel-runtime-requests runtime)))
      (when (lispm-kernel--current-p runtime pending)
        (lispm-kernel--call runtime (lispm-kernel--pending-callback pending) kind value)))))

(defun lispm-kernel--arm-expiry (runtime)
  "Check RUNTIME's deadlines every second while requests wait."
  (unless (lispm-kernel-runtime-expiry-timer runtime)
    (setf (lispm-kernel-runtime-expiry-timer runtime)
          (run-at-time 1 1 #'lispm-kernel--expire runtime))))

(defun lispm-kernel--expire (runtime)
  "End RUNTIME's requests past their deadlines with `timeout', cancelling them."
  (let ((now (float-time)) expired)
    (maphash (lambda (id pending)
               (let ((deadline (lispm-kernel--pending-deadline pending)))
                 (when (and deadline (> now deadline))
                   (push id expired))))
             (lispm-kernel-runtime-requests runtime))
    (dolist (id (sort expired #'<))
      (lispm-kernel-cancel runtime id)
      (lispm-kernel--deliver runtime id 'timeout nil t))
    (when (and (lispm-kernel-runtime-expiry-timer runtime)
               (zerop (hash-table-count (lispm-kernel-runtime-requests runtime))))
      (cancel-timer (lispm-kernel-runtime-expiry-timer runtime))
      (setf (lispm-kernel-runtime-expiry-timer runtime) nil))))

(defun lispm-kernel--abandon (runtime)
  "End every request of RUNTIME with `lost': its kernel will not answer."
  (unless (lispm-kernel-runtime-last-error runtime)
    (setf (lispm-kernel-runtime-last-error runtime) (lispm-kernel-runtime-exited runtime)))
  (unless (lispm-kernel-runtime-exited runtime)
    (setf (lispm-kernel-runtime-exited runtime) (lispm-kernel-runtime-last-error runtime)))
  (unless (lispm-kernel-runtime-exited-at runtime)
    (setf (lispm-kernel-runtime-exited-at runtime) (float-time)))
  (let (ids)
    (maphash (lambda (id _) (push id ids)) (lispm-kernel-runtime-requests runtime))
    (dolist (id (sort ids #'<))
      (lispm-kernel--deliver runtime id 'lost nil t)))
  (setf (lispm-kernel-runtime-waiters runtime) nil)
  (lispm-kernel--cancel-timers runtime)
  (when (process-live-p (lispm-kernel-runtime-process runtime))
    (delete-process (lispm-kernel-runtime-process runtime)))
  (let ((stderr (lispm-kernel-runtime-stderr runtime)))
    (when (process-live-p stderr)
      ;; What it said last, read before its pipe goes.
      (accept-process-output stderr 0 nil t)
      (delete-process stderr))))

(provide 'lispm-kernel)
;;; lispm-kernel.el ends here
