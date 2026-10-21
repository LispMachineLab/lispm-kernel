;;; lispm-kernel-sessions.el --- Incremental session discovery -*- lexical-binding: t; -*-

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
;; Opt-in API returning desktop-compatible plists. Native rows accumulate by ID;
;; completion returns newest-first sessions. Explicit caller-provided Elisp fallback
;; retains availability if the module is missing or a scan fails. It can still block
;; Emacs like the existing path; idle scheduling is not parallel execution.
;; Files the native scan has to skip (vanished, changing, unreadable) are counted
;; in the summary's :skipped and do not fail the scan; only :errors do.
;;; Code:
(require 'lispm-kernel)
(require 'parse-time)
(require 'seq)
(declare-function lispm-kernel-module-clear-session-cache "ext:lispm-kernel-module" ())
(defvar lispm-kernel-module-error nil "Last module loading failure, if any.")

(defun lispm-kernel-try-create (module)
  "Load MODULE and create a runtime, or return nil and record the failure."
  (condition-case error
      (progn
        (unless (featurep 'lispm-kernel-module) (module-load module))
        (prog1 (lispm-kernel-create) (setq lispm-kernel-module-error nil)))
    (error (setq lispm-kernel-module-error error) nil)))

(defun lispm-kernel-clear-session-cache ()
  "Free the module's cache of transcript heads, when the module is loaded."
  (when (fboundp 'lispm-kernel-module-clear-session-cache)
    (lispm-kernel-module-clear-session-cache)))

(defun lispm-kernel-sessions--row (text)
  "Convert bounded JSON TEXT into a desktop-compatible session plist."
  (let* ((row (json-parse-string text :object-type 'plist :null-object nil :false-object nil))
         (agent (pcase (plist-get row :agent) ("codex" 'codex) ("claude" 'claude)
                       (_ (error "Unknown session agent"))))
         (stamp (plist-get row :started)))
    (unless (and (stringp (plist-get row :id)) (stringp (plist-get row :cwd))
                 (stringp (plist-get row :file)) (stringp (plist-get row :title))
                 (numberp (plist-get row :time)))
      (error "Malformed native session row"))
    (plist-put row :agent agent)
    (plist-put row :started (when stamp (ignore-errors (float-time (parse-iso8601-time-string stamp)))))
    row))

(cl-defun lispm-kernel-scan-sessions (runtime agent root callback
                                              &key (owner 0) (generation 0) fallback (max-sessions 200000)
                                              (timeout lispm-kernel-request-timeout))
  "Scan local ROOT for AGENT, calling CALLBACK with (SESSIONS SUMMARY).
RUNTIME may be nil when the module is unavailable. FALLBACK is a zero-argument
function returning sessions via the current Elisp path. It runs asynchronously
on the Emacs thread, so it retains the old path's latency limits.
Native admission busy/capacity is returned for caller retry, without fallback.
Superseded generations receive no callbacks. Cancellation returns :cancelled t.
The final session collection is capped by MAX-SESSIONS, separate from native
queue/cache limits. A scan that takes longer than TIMEOUT seconds is cancelled
and fails.  Native scan errors do not publish an incomplete final list.
CALLBACK is called at most once."
  (unless (memq agent '(codex claude)) (error "Unsupported session agent"))
  (unless (and (integerp max-sessions) (> max-sessions 0)) (error "Invalid session limit"))
  (let ((runtime (and runtime (not (lispm-kernel-runtime-closed runtime)) runtime))
        (sessions (make-hash-table :test #'equal)) request finished limit-hit)
    (cl-labels
        ((active ()
           (or (null runtime)
               (and (not (lispm-kernel-runtime-closed runtime))
                    (= generation (gethash owner (lispm-kernel-runtime-generations runtime) 0)))))
         (finish (rows summary)
           (unless finished
             (setq finished t)
             (when (active) (funcall callback rows summary))))
         (fail (reason)
           (if fallback
               (run-at-time 0 nil
                            (lambda ()
                              (when (active)
                                (condition-case error
                                    (finish (funcall fallback) (list :source 'elisp :native-error reason))
                                  (error (finish nil (list :error error :native-error reason)))))))
             (finish nil (list :error reason))))
         (chunk (text)
           (unless limit-hit
             (condition-case error
                 (let* ((row (lispm-kernel-sessions--row text))
                        (key (cons (plist-get row :agent) (plist-get row :id)))
                        (old (gethash key sessions)))
                   (if (and (not old) (>= (hash-table-count sessions) max-sessions))
                       (progn (setq limit-hit 'session-limit)
                              (lispm-kernel-cancel runtime request))
                     (when (or (not old) (> (plist-get row :time) (plist-get old :time)))
                       (puthash key row sessions))))
               (error (setq limit-hit error)
                      (lispm-kernel-cancel runtime request)))))
         (success (text)
           (let ((summary (condition-case error
                              (json-parse-string text :object-type 'plist)
                            (error (list :errors 1 :malformed error)))))
             (if (or limit-hit (> (or (plist-get summary :errors) 0) 0))
                 (fail (or limit-hit summary))
               (finish (sort (hash-table-values sessions)
                             (lambda (a b) (> (plist-get a :time) (plist-get b :time))))
                       summary)))))
      (if (or (null runtime) (lispm-kernel-runtime-closed runtime))
          (progn (fail 'module-unavailable) nil)
        (setq request
              (lispm-kernel-submit runtime (if (eq agent 'codex) 'codex-scan 'claude-scan) root
                                   :owner owner :generation generation :timeout timeout
                                   :on-result
                                   (lambda (event)
                                     (unless finished
                                       (pcase (aref event 4)
                                         ('chunk (chunk (aref event 5)))
                                         ('success (success (aref event 5)))
                                         ('cancelled (if limit-hit (fail limit-hit) (finish nil '(:cancelled t))))
                                         (kind (fail kind)))))))
        request))))

(provide 'lispm-kernel-sessions)
;;; lispm-kernel-sessions.el ends here
