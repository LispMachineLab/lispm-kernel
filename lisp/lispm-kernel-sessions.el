;;; lispm-kernel-sessions.el --- The agents' sessions, read by the kernel -*- lexical-binding: t; -*-

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

;; `lispm-kernel-scan-sessions' has the kernel read the Codex or Claude
;; Code sessions below a directory, as lispm-agent's own readers do, see
;; src/sessions.lisp, and gives them back as those readers do:
;;
;;   (:agent codex :id ID :cwd CWD :title TITLE :started FLOAT :file FILE :time FLOAT)
;;   (:agent claude :id ID :cwd CWD :title TITLE :file FILE :time FLOAT)
;;
;; newest first.  When the kernel cannot read them, the caller's own
;; reader, its FALLBACK, does, later, on Emacs's thread.

;;; Code:

(require 'lispm-kernel)
(require 'parse-time)

(defun lispm-kernel-sessions--session (agent row)
  "Return the session of AGENT the kernel sent as ROW, or nil when ROW is
not one."
  (let ((id (plist-get row :id))
        (cwd (plist-get row :cwd))
        (title (plist-get row :title))
        (file (plist-get row :file))
        (mtime (plist-get row :mtime)))
    (when (and (stringp id) (stringp cwd) (stringp title) (stringp file) (natnump mtime))
      (let ((time (float-time (cons mtime 1000000000))))
        (if (eq agent 'codex)
            (list :agent 'codex :id id :cwd cwd :title title
                  :started (when-let* ((stamp (plist-get row :started)))
                             (ignore-errors (float-time (parse-iso8601-time-string stamp))))
                  :file file :time time)
          (list :agent 'claude :id id :cwd cwd :title title :file file :time time))))))

(cl-defun lispm-kernel-scan-sessions (runtime agent root callback
                                              &key (owner 0) (generation 0) index fallback
                                              (timeout lispm-kernel-request-timeout))
  "Have RUNTIME's kernel read AGENT's sessions below ROOT, a local directory.
AGENT is `codex' or `claude'; INDEX is Codex's session index, whose
thread names title its sessions.  CALLBACK is called once, later, with
SESSIONS, newest first, and SUMMARY, a plist: the kernel's counts
\(:files :rows :empty :skipped :cached :truncated), or :cancelled t, or
:rejected and why, the caller retrying a scan rejected for `capacity'.
When the kernel fails to read them, or is not running, FALLBACK, a
function returning the sessions as the caller reads them itself, is
called on Emacs's thread instead, and SUMMARY says :source elisp and
:native-error why; without FALLBACK, SESSIONS is nil and SUMMARY says
:error why.  Superseding OWNER's GENERATION leaves CALLBACK uncalled.
Return the request's id, or nil when the kernel is not running."
  (unless (memq agent '(codex claude))
    (error "There is no agent %S to read sessions of" agent))
  (let ((rows nil)
        (finished nil))
    (cl-labels
        ((current-p ()
           (or (not runtime)
               (eql generation (gethash owner (lispm-kernel-runtime-generations runtime) 0))))
         (finish (sessions summary)
           (unless finished
             (setq finished t)
             (when (current-p)
               (funcall callback sessions summary))))
         (fail (reason)
           (if fallback
               (run-at-time 0 nil
                            (lambda ()
                              (when (and (not finished) (current-p))
                                (condition-case error
                                    (finish (funcall fallback) (list :source 'elisp :native-error reason))
                                  (error (finish nil (list :error error :native-error reason)))))))
             (finish nil (list :error reason))))
         (result (kind value)
           (pcase kind
             ('chunk
              (dolist (row value)
                (when-let* ((session (lispm-kernel-sessions--session agent row)))
                  (push session rows))))
             ('success
              ;; Sorted as the agents' list sorts, those of one time in the
              ;; order the kernel sent them, which is their readers'.
              (finish (sort (nreverse rows) (lambda (a b) (> (plist-get a :time) (plist-get b :time))))
                      value))
             ('cancelled (finish nil '(:cancelled t)))
             ('rejected (finish nil (list :rejected value)))
             (_ (fail (list kind value))))))
      (if (not (lispm-kernel-live-p runtime))
          (progn (fail 'kernel-not-running) nil)
        (condition-case error
            (lispm-kernel-submit runtime 'scan-sessions
                                 `(:agent ,agent :root ,(expand-file-name root)
                                          ,@(and index (list :index (expand-file-name index))))
                                 :owner owner :generation generation :timeout timeout
                                 :on-result #'result)
          ;; The kernel went away between asking whether it runs and asking it.
          (error (fail (list 'kernel-not-running (error-message-string error)))
                 nil))))))

(provide 'lispm-kernel-sessions)
;;; lispm-kernel-sessions.el ends here
