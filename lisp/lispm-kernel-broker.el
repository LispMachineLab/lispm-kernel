;;; lispm-kernel-broker.el --- The kernel's messages on the desktop's frame clock -*- lexical-binding: t; -*-

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

;; Take in one kernel's messages as a client of LispM Desktop's frame
;; clock (lispm-desktop-frame): after the terminals of each frame, within
;; what is left of the frame's budget.  The clock gives way to typing for
;; every client after the first, so terminals keep their own policy and
;; the kernel waits.

;;; Code:

(require 'lispm-kernel)
(declare-function lispm-desktop-frame-add-client "ext:lispm-desktop-frame" (name function &optional depth))
(declare-function lispm-desktop-frame-remove-client "ext:lispm-desktop-frame" (name))
(declare-function lispm-desktop-frame-request "ext:lispm-desktop-frame" (name))

(defconst lispm-kernel-broker-depth 10
  "Frame clock depth of the kernel: after the terminals, at depth 0.")

(defvar lispm-kernel-broker--runtime nil
  "The runtime whose messages the frame clock takes in, or nil.")

(defun lispm-kernel-broker-available-p ()
  "Return non-nil when LispM Desktop's frame clock can be loaded."
  (and (require 'lispm-desktop-frame nil t)
       (fboundp 'lispm-desktop-frame-add-client)))

(defun lispm-kernel-broker--schedule (runtime)
  "Ask the frame clock for a frame when RUNTIME is the broker's.
Return non-nil when it took RUNTIME, see `lispm-kernel-scheduler'."
  (when (and lispm-kernel-broker--runtime (eq runtime lispm-kernel-broker--runtime))
    (lispm-desktop-frame-request 'lispm-kernel)
    t))

(defun lispm-kernel-broker--frame (deadline)
  "Take in the broker's runtime's messages until DEADLINE, a `float-time'.
Return non-nil while there are more, so the clock comes back."
  (when-let* ((runtime lispm-kernel-broker--runtime))
    (let ((lispm-kernel-slice-seconds (max 0 (- deadline (float-time)))))
      (lispm-kernel-dispatch runtime))
    (and (not (lispm-kernel-runtime-closed runtime))
         (lispm-kernel--lines-p runtime)
         t)))

(defun lispm-kernel-broker-start (runtime)
  "Take in RUNTIME's messages on LispM Desktop's frame clock instead of timers."
  (unless (lispm-kernel-broker-available-p)
    (user-error "This LispM Desktop has no frame clock (lispm-desktop-frame); update it"))
  (when lispm-kernel-broker--runtime (lispm-kernel-broker-stop))
  (setq lispm-kernel-broker--runtime runtime
        lispm-kernel-scheduler #'lispm-kernel-broker--schedule)
  (lispm-desktop-frame-add-client 'lispm-kernel #'lispm-kernel-broker--frame
                                  lispm-kernel-broker-depth)
  (when-let* ((timer (lispm-kernel-runtime-timer runtime)))
    (cancel-timer timer)
    (setf (lispm-kernel-runtime-timer runtime) nil))
  (when (lispm-kernel--lines-p runtime)
    (lispm-desktop-frame-request 'lispm-kernel)))

(defun lispm-kernel-broker-stop ()
  "Leave the frame clock; the runtime's messages are taken in by timers again."
  (let ((runtime lispm-kernel-broker--runtime))
    (setq lispm-kernel-broker--runtime nil)
    (when (eq lispm-kernel-scheduler #'lispm-kernel-broker--schedule)
      (setq lispm-kernel-scheduler nil))
    (when (fboundp 'lispm-desktop-frame-remove-client)
      (lispm-desktop-frame-remove-client 'lispm-kernel))
    (when (and runtime (not (lispm-kernel-runtime-closed runtime)) (lispm-kernel--lines-p runtime))
      (lispm-kernel--schedule runtime))))

(defun lispm-kernel-broker-unload-function ()
  "Leave the frame clock before `unload-feature' removes this library."
  (lispm-kernel-broker-stop)
  nil)

(provide 'lispm-kernel-broker)
;;; lispm-kernel-broker.el ends here
