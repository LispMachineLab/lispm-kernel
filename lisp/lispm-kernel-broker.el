;;; lispm-kernel-broker.el --- Shared cooperative frontend budget -*- lexical-binding: t; -*-

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
;; Coordinate one desktop kernel runtime and the existing terminal frame scheduler.
;; PTY threads, parsing, retained status/exit/clipboard events, visible-first ordering
;; and actual rendering remain the terminal module's responsibility.
;;; Code:
(require 'lispm-kernel)
(declare-function lispm-kernel-module-monotonic "ext:lispm-kernel-module" ())
(defvar lispm-desktop-term--last-frame)
(defvar lispm-desktop-term-frame-interval)
(defvar lispm-desktop-term-frame-budget)
(defvar lispm-desktop-term--timer)
(declare-function lispm-desktop-term--tick "ext:lispm-desktop-term" ())
(declare-function lispm-desktop-term--schedule "ext:lispm-desktop-term" ())
(defcustom lispm-kernel-broker-slice-seconds 0.008
  "Soft total budget for terminal drawing and native result application."
  :type 'number :group 'lispm-kernel)
(defvar lispm-kernel-broker--runtime nil)
(defvar lispm-kernel-broker--timer nil)
(defvar lispm-kernel-broker--terminal-due nil)
(defvar lispm-kernel-broker--kernel-due nil)
(defvar lispm-kernel-broker--running nil)
(defvar lispm-kernel-broker-overruns 0)
(defvar lispm-kernel-broker-last-error nil)

(defun lispm-kernel-broker--arm ()
  "Schedule one timer for the earliest outstanding cooperative slice."
  (unless lispm-kernel-broker--running
    (when lispm-kernel-broker--timer (cancel-timer lispm-kernel-broker--timer))
    (setq lispm-kernel-broker--timer nil)
    (let ((times (delq nil (list lispm-kernel-broker--terminal-due lispm-kernel-broker--kernel-due))))
      (when times
        ;; Positive delay returns control to the event loop between busy slices.
        (setq lispm-kernel-broker--timer
              (run-at-time (max 0.001 (- (apply #'min times) (lispm-kernel-module-monotonic)))
                           nil #'lispm-kernel-broker--tick))))))

(defun lispm-kernel-broker--terminal-schedule (original &rest args)
  "Coordinate ORIGINAL terminal scheduler without changing its frame interval."
  (if (null lispm-kernel-broker--runtime) (apply original args)
    (unless lispm-kernel-broker--terminal-due
      (setq lispm-kernel-broker--terminal-due
            (+ (lispm-kernel-module-monotonic)
               (max 0 (- (+ lispm-desktop-term--last-frame lispm-desktop-term-frame-interval)
                         (float-time))))))
    (lispm-kernel-broker--arm)))

(defun lispm-kernel-broker--kernel-schedule (original runtime &optional immediate)
  "Coordinate RUNTIME dispatch while keeping unrelated runtimes independent."
  (if (not (eq runtime lispm-kernel-broker--runtime)) (funcall original runtime immediate)
    (let ((due (+ (lispm-kernel-module-monotonic) (if immediate 0.001 lispm-kernel-poll-seconds))))
      (setq lispm-kernel-broker--kernel-due
            (min due (or lispm-kernel-broker--kernel-due due))))
    (lispm-kernel-broker--arm)))

(defun lispm-kernel-broker--tick ()
  "Run due terminal work first, then kernel callbacks within the remaining budget."
  (setq lispm-kernel-broker--timer nil)
  (when (and lispm-kernel-broker--runtime (not lispm-kernel-broker--running))
    (let* ((lispm-kernel-broker--running t)
           (start (lispm-kernel-module-monotonic))
           (deadline (+ start lispm-kernel-broker-slice-seconds)))
      (unwind-protect
          (if (input-pending-p)
              (progn
                (when lispm-kernel-broker--terminal-due
                  (setq lispm-kernel-broker--terminal-due (+ start lispm-kernel-poll-seconds)))
                (when lispm-kernel-broker--kernel-due
                  (setq lispm-kernel-broker--kernel-due (+ start lispm-kernel-poll-seconds))))
            (when (and lispm-kernel-broker--terminal-due
                       (<= lispm-kernel-broker--terminal-due start))
              (setq lispm-kernel-broker--terminal-due nil)
              (let ((lispm-desktop-term-frame-budget (min lispm-desktop-term-frame-budget
                                                          lispm-kernel-broker-slice-seconds)))
                (condition-case error
                    (lispm-desktop-term--tick)
                  (error (setq lispm-kernel-broker-last-error error)))))
            (when (and lispm-kernel-broker--kernel-due
                       (<= lispm-kernel-broker--kernel-due (lispm-kernel-module-monotonic))
                       (< (lispm-kernel-module-monotonic) deadline)
                       (not (input-pending-p)))
              (setq lispm-kernel-broker--kernel-due nil)
              (let ((lispm-kernel-slice-seconds
                     (min lispm-kernel-slice-seconds (- deadline (lispm-kernel-module-monotonic)))))
                (condition-case error
                    (lispm-kernel-dispatch lispm-kernel-broker--runtime)
                  (error
                   (setq lispm-kernel-broker-last-error error
                         lispm-kernel-broker--kernel-due
                         (+ (lispm-kernel-module-monotonic) lispm-kernel-poll-seconds)))))))
        (when (> (lispm-kernel-module-monotonic) deadline) (cl-incf lispm-kernel-broker-overruns))))
    ;; Running is dynamically rebound above; arming now cannot recurse.
    (lispm-kernel-broker--arm)))

(defun lispm-kernel-broker-start (runtime)
  "Coordinate RUNTIME with the loaded desktop terminal scheduler."
  (when lispm-kernel-broker--runtime (lispm-kernel-broker-stop))
  (require 'lispm-desktop-term)
  (setq lispm-kernel-broker--runtime runtime)
  (advice-add 'lispm-desktop-term--schedule :around #'lispm-kernel-broker--terminal-schedule)
  (advice-add 'lispm-kernel--schedule :around #'lispm-kernel-broker--kernel-schedule)
  (when lispm-desktop-term--timer
    (cancel-timer lispm-desktop-term--timer)
    (setq lispm-desktop-term--timer nil)
    (lispm-desktop-term--schedule))
  (when-let* ((timer (lispm-kernel-runtime-timer runtime)))
    (cancel-timer timer)
    (setf (lispm-kernel-runtime-timer runtime) nil)
    (lispm-kernel--schedule runtime)))

(defun lispm-kernel-broker-stop ()
  "Restore the original terminal scheduler and leave no broker timer behind."
  (let ((runtime lispm-kernel-broker--runtime)
        (terminal-pending lispm-kernel-broker--terminal-due))
    (setq lispm-kernel-broker--runtime nil)
    (when lispm-kernel-broker--timer (cancel-timer lispm-kernel-broker--timer))
    (setq lispm-kernel-broker--timer nil lispm-kernel-broker--terminal-due nil
          lispm-kernel-broker--kernel-due nil)
    (advice-remove 'lispm-desktop-term--schedule #'lispm-kernel-broker--terminal-schedule)
    (advice-remove 'lispm-kernel--schedule #'lispm-kernel-broker--kernel-schedule)
    (when terminal-pending (lispm-desktop-term--schedule))
    (when (and runtime (not (lispm-kernel-runtime-closed runtime))
               (> (hash-table-count (lispm-kernel-runtime-callbacks runtime)) 0))
      (lispm-kernel--schedule runtime))))

(provide 'lispm-kernel-broker)
;;; lispm-kernel-broker.el ends here
