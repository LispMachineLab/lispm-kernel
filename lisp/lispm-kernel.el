;;; lispm-kernel.el --- Cooperative native job dispatch -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-kernel
;; Version: 0.1.0
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
;; Experimental opt-in bridge. Load the built module explicitly before creating
;; a runtime. Poll only while requests exist; native socket notifications are not
;; wired to Emacs yet. A callback is cooperative and cannot be preempted.
;; Every accepted request ends in exactly one final event for its callback: the
;; native outcome, or `timeout'/`lost' when the runtime cannot deliver one.
;;; Code:
(require 'cl-lib)
(declare-function lispm-kernel-module-create "ext:lispm-kernel-module" ())
(declare-function lispm-kernel-module-epoch "ext:lispm-kernel-module" (handle))
(declare-function lispm-kernel-module-protocol-version "ext:lispm-kernel-module" ())
(declare-function lispm-kernel-module-monotonic "ext:lispm-kernel-module" ())
(declare-function lispm-kernel-module-ready-p "ext:lispm-kernel-module" (handle))
(declare-function lispm-kernel-module-submit-echo "ext:lispm-kernel-module" (handle owner generation input))
(declare-function lispm-kernel-module-submit-scan "ext:lispm-kernel-module" (handle owner generation root agent))
(declare-function lispm-kernel-module-drain "ext:lispm-kernel-module" (handle items bytes))
(declare-function lispm-kernel-module-cancel "ext:lispm-kernel-module" (handle request))
(declare-function lispm-kernel-module-supersede "ext:lispm-kernel-module" (handle owner generation))
(declare-function lispm-kernel-module-shutdown "ext:lispm-kernel-module" (handle))

(defconst lispm-kernel-protocol-version 2
  "The module protocol this frontend speaks; other modules fall back.")

(defgroup lispm-kernel nil "Native background work for LispM." :group 'applications)
(defcustom lispm-kernel-slice-seconds 0.003
  "Soft dispatch budget in seconds; one callback can exceed it."
  :type 'number)
(defcustom lispm-kernel-poll-seconds 0.01
  "Polling interval while requests are outstanding."
  :type 'number)
(defcustom lispm-kernel-request-timeout 60
  "Seconds a request may take before its callback gets a `timeout' event.
The native work is cancelled.  Nil waits for ever."
  :type '(choice (const :tag "Never" nil) number))

(defvar lispm-kernel-scheduler nil
  "Nil, or a function that schedules the dispatch of a runtime itself.
It is called with RUNTIME and IMMEDIATE and returns non-nil when it took
RUNTIME; otherwise the runtime schedules itself with a timer.")

(defvar lispm-kernel--runtimes nil
  "Runtimes not yet shut down, so unloading can close them.")

(cl-defstruct (lispm-kernel-runtime (:constructor lispm-kernel--runtime))
  handle epoch timer (closed nil) (dispatching nil) (overruns 0) last-error
  (callbacks (make-hash-table :test #'eql))
  (generations (make-hash-table :test #'eql)))

(cl-defstruct (lispm-kernel--pending (:constructor lispm-kernel--pending) (:copier nil))
  "A submitted request waiting for its final event."
  callback owner generation deadline)

(defun lispm-kernel-create ()
  "Create a native runtime after `lispm-kernel-module' has been loaded."
  (unless (featurep 'lispm-kernel-module)
    (error "Build and module-load lispm-kernel-module first"))
  (unless (and (fboundp 'lispm-kernel-module-protocol-version)
               (eql (lispm-kernel-module-protocol-version) lispm-kernel-protocol-version))
    (error "Incompatible kernel module protocol"))
  (let* ((handle (lispm-kernel-module-create))
         (runtime (lispm-kernel--runtime :handle handle :epoch (lispm-kernel-module-epoch handle))))
    (push runtime lispm-kernel--runtimes)
    runtime))

(defun lispm-kernel--tick (runtime)
  "Run one scheduled RUNTIME dispatch."
  (setf (lispm-kernel-runtime-timer runtime) nil)
  (lispm-kernel-dispatch runtime))

(defun lispm-kernel--schedule (runtime &optional immediate)
  "Schedule RUNTIME; IMMEDIATE yields to the event loop without a poll delay.
`lispm-kernel-scheduler', when set, may take the runtime instead."
  (unless (and lispm-kernel-scheduler (funcall lispm-kernel-scheduler runtime immediate))
    (when (and immediate (lispm-kernel-runtime-timer runtime))
      (cancel-timer (lispm-kernel-runtime-timer runtime))
      (setf (lispm-kernel-runtime-timer runtime) nil))
    (unless (lispm-kernel-runtime-timer runtime)
      (setf (lispm-kernel-runtime-timer runtime)
            (run-at-time (if immediate 0.001 lispm-kernel-poll-seconds) nil
                         #'lispm-kernel--tick runtime)))))

(defun lispm-kernel-pending-p (runtime)
  "Return non-nil while RUNTIME has requests waiting for final events."
  (and (not (lispm-kernel-runtime-closed runtime))
       (> (hash-table-count (lispm-kernel-runtime-callbacks runtime)) 0)))

(cl-defun lispm-kernel-submit (runtime kind input &key (owner 0) (generation 0) on-result
                                       (timeout lispm-kernel-request-timeout))
  "Submit KIND with INPUT to RUNTIME and return a request ID.
KIND is echo, codex-scan or claude-scan.  Scan INPUT is an explicit local
root directory.  ON-RESULT receives event vectors
[epoch request owner generation kind text key]: `chunk' events, then one
final event, `success', `failed', `cancelled', `panicked' or
`output-too-large' from the module, or `timeout' after TIMEOUT seconds
\(default `lispm-kernel-request-timeout'), or `lost' when the runtime can no
longer deliver results.  Results of superseded generations are not delivered.
Rejected admission returns busy, capacity, closed or an input-error symbol."
  (when (lispm-kernel-runtime-closed runtime) (error "Runtime is closed"))
  (let ((current (gethash owner (lispm-kernel-runtime-generations runtime) 0)))
    (when (< generation current) (error "Stale generation"))
    (let ((request
           (pcase kind
             ('echo (lispm-kernel-module-submit-echo
                     (lispm-kernel-runtime-handle runtime) owner generation input))
             ((or 'codex-scan 'claude-scan)
              (lispm-kernel-module-submit-scan
               (lispm-kernel-runtime-handle runtime) owner generation
               (expand-file-name input) (if (eq kind 'codex-scan) "codex" "claude")))
             (_ (error "Unsupported job kind: %S" kind)))))
      (when (integerp request)
        (puthash owner generation (lispm-kernel-runtime-generations runtime))
        (puthash request
                 (lispm-kernel--pending :callback on-result :owner owner :generation generation
                                        :deadline (and timeout (+ (float-time) timeout)))
                 (lispm-kernel-runtime-callbacks runtime))
        (lispm-kernel--schedule runtime))
      request)))

(defun lispm-kernel-supersede (runtime owner generation)
  "Reject older OWNER results immediately and request their cancellation.
Return busy when native cancellation should be retried."
  (let ((generations (lispm-kernel-runtime-generations runtime)))
    (when (< generation (gethash owner generations 0)) (error "Generation moved backwards"))
    (puthash owner generation generations)
    (lispm-kernel-module-supersede (lispm-kernel-runtime-handle runtime) owner generation)))

(defun lispm-kernel-cancel (runtime request)
  "Request cooperative cancellation of REQUEST in RUNTIME; may return busy."
  (lispm-kernel-module-cancel (lispm-kernel-runtime-handle runtime) request))

(defun lispm-kernel--call (runtime pending event)
  "Give PENDING's callback EVENT, recording an error in RUNTIME."
  (when-let* ((callback (lispm-kernel--pending-callback pending)))
    (let ((started (lispm-kernel-module-monotonic)))
      (condition-case error
          (funcall callback event)
        (error (setf (lispm-kernel-runtime-last-error runtime) error)))
      (when (> (- (lispm-kernel-module-monotonic) started) lispm-kernel-slice-seconds)
        (cl-incf (lispm-kernel-runtime-overruns runtime))))))

(defun lispm-kernel--current-p (runtime pending)
  "Return non-nil when PENDING's generation is still current in RUNTIME."
  (= (lispm-kernel--pending-generation pending)
     (gethash (lispm-kernel--pending-owner pending) (lispm-kernel-runtime-generations runtime) 0)))

(defun lispm-kernel--end (runtime request kind)
  "End REQUEST of RUNTIME with a frontend-made final event of KIND."
  (when-let* ((pending (gethash request (lispm-kernel-runtime-callbacks runtime))))
    (remhash request (lispm-kernel-runtime-callbacks runtime))
    (when (lispm-kernel--current-p runtime pending)
      (lispm-kernel--call runtime pending
                          (vector (lispm-kernel-runtime-epoch runtime) request
                                  (lispm-kernel--pending-owner pending)
                                  (lispm-kernel--pending-generation pending) kind "" nil)))))

(defun lispm-kernel--expire (runtime)
  "End RUNTIME's requests past their deadline with `timeout', cancelling them."
  (let ((now (float-time)) expired)
    (maphash (lambda (request pending)
               (when-let* ((deadline (lispm-kernel--pending-deadline pending)))
                 (when (> now deadline) (push request expired))))
             (lispm-kernel-runtime-callbacks runtime))
    (dolist (request expired)
      ;; A busy cancel is harmless: the late outcome finds no callback.
      (lispm-kernel-cancel runtime request)
      (lispm-kernel--end runtime request 'timeout))))

(defun lispm-kernel--abandon (runtime reason)
  "End every request of RUNTIME with `lost' after a persistent REASON."
  (setf (lispm-kernel-runtime-last-error runtime) reason)
  (let (requests)
    (maphash (lambda (request _) (push request requests)) (lispm-kernel-runtime-callbacks runtime))
    (dolist (request requests)
      (lispm-kernel--end runtime request 'lost))))

(defun lispm-kernel-dispatch (runtime)
  "Dispatch RUNTIME without reentrancy, yielding between bounded slices."
  (unless (or (lispm-kernel-runtime-closed runtime)
              (lispm-kernel-runtime-dispatching runtime))
    (setf (lispm-kernel-runtime-dispatching runtime) t)
    (unwind-protect
        (progn
          (lispm-kernel--dispatch runtime)
          (unless (lispm-kernel-runtime-closed runtime)
            (lispm-kernel--expire runtime)))
      (setf (lispm-kernel-runtime-dispatching runtime) nil)
      (if (lispm-kernel-pending-p runtime)
          (lispm-kernel--schedule
           runtime (and (not (input-pending-p))
                        (eq t (lispm-kernel-module-ready-p
                               (lispm-kernel-runtime-handle runtime)))))
        (when-let* ((timer (lispm-kernel-runtime-timer runtime)))
          (cancel-timer timer)
          (setf (lispm-kernel-runtime-timer runtime) nil))))))

(defun lispm-kernel--dispatch (runtime)
  "Apply bounded native results until input waits or the soft budget expires."
  (let ((deadline (+ (lispm-kernel-module-monotonic) (max 0 lispm-kernel-slice-seconds)))
        (remaining 16)
        (continue t))
    (while (and continue (not (lispm-kernel-runtime-closed runtime)) (> remaining 0)
                (< (lispm-kernel-module-monotonic) deadline) (not (input-pending-p)))
      (setq remaining (1- remaining))
      ;; Drain one event, so yielding leaves retained work in the bounded core.
      (let ((events (lispm-kernel-module-drain (lispm-kernel-runtime-handle runtime) 1 65536)))
        (cond
         ((and (vectorp events) (> (length events) 0))
          (let* ((event (aref events 0))
                 (request (aref event 1))
                 (callbacks (lispm-kernel-runtime-callbacks runtime))
                 (pending (gethash request callbacks)))
            (unless (eq (aref event 4) 'chunk) (remhash request callbacks))
            (when (and pending
                       (= (aref event 0) (lispm-kernel-runtime-epoch runtime))
                       (lispm-kernel--current-p runtime pending))
              (lispm-kernel--call runtime pending event))))
         ((or (vectorp events) (eq events 'busy)) (setq continue nil))
         ;; Anything else will not change by retrying: stop polling for ever.
         (t (lispm-kernel--abandon runtime events)
            (setq continue nil)))))))

(defun lispm-kernel-shutdown (runtime)
  "Close RUNTIME without joining workers or waiting for jobs.
Waiting callbacks are dropped without a final event."
  (unless (lispm-kernel-runtime-closed runtime)
    (setf (lispm-kernel-runtime-closed runtime) t)
    (setq lispm-kernel--runtimes (delq runtime lispm-kernel--runtimes))
    (when-let* ((timer (lispm-kernel-runtime-timer runtime))) (cancel-timer timer))
    (setf (lispm-kernel-runtime-timer runtime) nil)
    (clrhash (lispm-kernel-runtime-callbacks runtime))
    (clrhash (lispm-kernel-runtime-generations runtime))
    (lispm-kernel-module-shutdown (lispm-kernel-runtime-handle runtime))))

(defun lispm-kernel-unload-function ()
  "Shut every runtime down before `unload-feature' removes this library."
  (mapc #'lispm-kernel-shutdown (copy-sequence lispm-kernel--runtimes))
  nil)

(provide 'lispm-kernel)
;;; lispm-kernel.el ends here
