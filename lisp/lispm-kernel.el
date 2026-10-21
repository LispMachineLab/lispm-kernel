;;; lispm-kernel.el --- Cooperative native job dispatch -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-kernel
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


(defgroup lispm-kernel nil "Native background work for LispM." :group 'applications)
(defcustom lispm-kernel-slice-seconds 0.003
  "Soft dispatch budget in seconds; one callback can exceed it."
  :type 'number)
(defcustom lispm-kernel-poll-seconds 0.01
  "Polling interval while requests are outstanding."
  :type 'number)
(cl-defstruct (lispm-kernel-runtime (:constructor lispm-kernel--runtime))
  handle epoch timer (closed nil) (dispatching nil) (overruns 0) last-error
  (callbacks (make-hash-table :test #'eql))
  (generations (make-hash-table :test #'eql)))

(defun lispm-kernel-create ()
  "Create a native runtime after `lispm-kernel-module' has been loaded."
  (unless (featurep 'lispm-kernel-module)
    (error "Build and module-load lispm-kernel-module first"))
  (unless (and (fboundp 'lispm-kernel-module-protocol-version)
               (= (lispm-kernel-module-protocol-version) 1))
    (error "Incompatible kernel module protocol"))
  (let ((handle (lispm-kernel-module-create)))
    (lispm-kernel--runtime :handle handle :epoch (lispm-kernel-module-epoch handle))))

(defun lispm-kernel--tick (runtime)
  "Run one scheduled RUNTIME dispatch."
  (setf (lispm-kernel-runtime-timer runtime) nil)
  (lispm-kernel-dispatch runtime))

(defun lispm-kernel--schedule (runtime &optional immediate)
  "Schedule RUNTIME; IMMEDIATE yields to the event loop without a poll delay."
  (when (and immediate (lispm-kernel-runtime-timer runtime))
    (cancel-timer (lispm-kernel-runtime-timer runtime))
    (setf (lispm-kernel-runtime-timer runtime) nil))
  (unless (lispm-kernel-runtime-timer runtime)
    (setf (lispm-kernel-runtime-timer runtime)
          (run-at-time (if immediate 0.001 lispm-kernel-poll-seconds) nil
                       #'lispm-kernel--tick runtime))))

(cl-defun lispm-kernel-submit (runtime kind input &key (owner 0) (generation 0) on-result)
  "Submit KIND with INPUT to RUNTIME and return a request ID.
KIND is echo, codex-scan or claude-scan.  Scan INPUT is an explicit local
root directory.  ON-RESULT receives an event vector:
[epoch request owner generation kind text key].
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
        (puthash request on-result (lispm-kernel-runtime-callbacks runtime))
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

(defun lispm-kernel-dispatch (runtime)
  "Dispatch RUNTIME without reentrancy, yielding between bounded slices."
  (unless (or (lispm-kernel-runtime-closed runtime)
              (lispm-kernel-runtime-dispatching runtime))
    (setf (lispm-kernel-runtime-dispatching runtime) t)
    (unwind-protect (lispm-kernel--dispatch runtime)
      (setf (lispm-kernel-runtime-dispatching runtime) nil)
      (when (and (not (lispm-kernel-runtime-closed runtime))
                 (> (hash-table-count (lispm-kernel-runtime-callbacks runtime)) 0))
        (lispm-kernel--schedule
         runtime (and (not (input-pending-p))
                      (eq t (lispm-kernel-module-ready-p
                             (lispm-kernel-runtime-handle runtime)))))))))

(defun lispm-kernel--dispatch (runtime)
  "Apply bounded native results until input waits or the soft budget expires."
  (unless (lispm-kernel-runtime-closed runtime)
    (let ((deadline (+ (lispm-kernel-module-monotonic) (max 0 lispm-kernel-slice-seconds)))
          (remaining 16)
          (continue t))
      (while (and continue (not (lispm-kernel-runtime-closed runtime)) (> remaining 0) (< (lispm-kernel-module-monotonic) deadline)
                  (not (input-pending-p)))
        (setq remaining (1- remaining))
        ;; Drain one event, so yielding leaves retained work in the bounded core.
        (let ((events (lispm-kernel-module-drain
                       (lispm-kernel-runtime-handle runtime) 1 65536)))
          (if (not (and (vectorp events) (> (length events) 0)))
              (progn
                (when (and events (not (vectorp events)) (not (eq events 'busy)))
                  (setf (lispm-kernel-runtime-last-error runtime) events))
                (setq continue nil))
            (let* ((event (aref events 0))
                   (request (aref event 1))
                   (callbacks (lispm-kernel-runtime-callbacks runtime))
                   (callback (gethash request callbacks))
                   (terminal (not (eq (aref event 4) 'chunk))))
              (when terminal (remhash request callbacks))
              (when (and callback
                         (= (aref event 0) (lispm-kernel-runtime-epoch runtime))
                         (= (aref event 3)
                            (gethash (aref event 2) (lispm-kernel-runtime-generations runtime) 0)))
                (let ((started (lispm-kernel-module-monotonic)))
                  (condition-case error
                      (funcall callback event)
                    (error (setf (lispm-kernel-runtime-last-error runtime) error)))
                  (when (> (- (lispm-kernel-module-monotonic) started) lispm-kernel-slice-seconds)
                    (cl-incf (lispm-kernel-runtime-overruns runtime)))))))))
      (when (zerop (hash-table-count (lispm-kernel-runtime-callbacks runtime)))
	(when-let* ((timer (lispm-kernel-runtime-timer runtime)))
          (cancel-timer timer)
          (setf (lispm-kernel-runtime-timer runtime) nil))))))

(defun lispm-kernel-shutdown (runtime)
  "Close RUNTIME without joining workers or waiting for jobs."
  (unless (lispm-kernel-runtime-closed runtime)
    (setf (lispm-kernel-runtime-closed runtime) t)
    (when-let* ((timer (lispm-kernel-runtime-timer runtime))) (cancel-timer timer))
    (setf (lispm-kernel-runtime-timer runtime) nil)
    (clrhash (lispm-kernel-runtime-callbacks runtime))
    (clrhash (lispm-kernel-runtime-generations runtime))
    (lispm-kernel-module-shutdown (lispm-kernel-runtime-handle runtime))))

(provide 'lispm-kernel)
;;; lispm-kernel.el ends here
