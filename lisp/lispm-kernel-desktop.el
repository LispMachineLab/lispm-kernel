;;; lispm-kernel-desktop.el --- Opt-in desktop session acceleration -*- lexical-binding: t; -*-

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
;; Give LispM Desktop's agents sidebar the Codex and Claude sessions without
;; blocking.  `lispm-kernel-desktop-mode' registers session readers with the
;; desktop (`lispm-desktop-agent-add-session-reader'): they answer with the last
;; native snapshot, or `pending' before the first, and scan again in the
;; background once the snapshot is older than `lispm-kernel-desktop-cache-seconds'
;; or the sidebar reads sessions anew.  Every other caller, the session picker
;; among them, keeps the desktop's own synchronous readers.  Kernel dispatch runs
;; on the desktop's frame clock, see lispm-kernel-broker.  Nothing is advised.
;;; Code:
(require 'lispm-kernel-sessions)
(require 'lispm-kernel-broker)
(defvar lispm-desktop-agent-codex-sessions-directory)
(defvar lispm-desktop-agent-claude-projects-directory)
(defvar lispm-desktop-agent-reread-sessions-hook)
(declare-function lispm-desktop-agent-add-session-reader "ext:lispm-desktop-ai" (agent reader))
(declare-function lispm-desktop-agent-remove-session-reader "ext:lispm-desktop-ai" (agent))
(declare-function lispm-desktop-agent-sessions-arrived "ext:lispm-desktop-ai" ())

(defcustom lispm-kernel-desktop-module nil
  "Explicit path to the built lispm-kernel Emacs module."
  :type '(choice (const nil) file) :group 'lispm-kernel)
(defcustom lispm-kernel-desktop-cache-seconds 2
  "Maximum snapshot age before a reader schedules a background refresh."
  :type 'number :group 'lispm-kernel)
(defcustom lispm-kernel-desktop-scan-timeout 60
  "Seconds a native scan may take before the desktop's own reader is used."
  :type 'number :group 'lispm-kernel)

(defconst lispm-kernel-desktop--agents
  '((codex :owner 1 :root lispm-desktop-agent-codex-sessions-directory
           :read lispm-desktop-agent-codex-sessions)
    (claude :owner 2 :root lispm-desktop-agent-claude-projects-directory
            :read lispm-desktop-agent-claude-sessions))
  "The agents read natively: their kernel owner, root variable and own reader.")

(defvar lispm-kernel-desktop--runtime nil)
(defvar lispm-kernel-desktop--cache (make-hash-table :test #'eq)
  "Per agent, a plist (:root :generation :sessions :known :time :request
:started :retry-timer).  :known is non-nil once a snapshot exists, :time
is when it was taken, nil when it must be taken anew.")
(defvar lispm-kernel-desktop-last-error nil)
(defvar lispm-kernel-desktop-mode nil)

(defun lispm-kernel-desktop--spec (agent property)
  "Return PROPERTY of AGENT in `lispm-kernel-desktop--agents'."
  (plist-get (alist-get agent lispm-kernel-desktop--agents) property))

(defun lispm-kernel-desktop--forget-timer (entry)
  "Cancel ENTRY's pending admission retry."
  (when-let* ((timer (plist-get entry :retry-timer))) (cancel-timer timer)))

(defun lispm-kernel-desktop--entry (agent root)
  "Return AGENT's cache entry for ROOT; a new ROOT starts a new generation."
  (let ((entry (gethash agent lispm-kernel-desktop--cache)))
    (unless (and entry (equal root (plist-get entry :root)))
      (let ((generation (1+ (or (plist-get entry :generation) 0))))
        (when entry
          (lispm-kernel-desktop--forget-timer entry)
          (lispm-kernel-supersede lispm-kernel-desktop--runtime
                                  (lispm-kernel-desktop--spec agent :owner) generation))
        (setq entry (list :root root :generation generation))
        (puthash agent entry lispm-kernel-desktop--cache)))
    entry))

(defun lispm-kernel-desktop--update (agent generation &rest properties)
  "Set PROPERTIES of AGENT's entry while its generation is GENERATION."
  (let ((entry (gethash agent lispm-kernel-desktop--cache)))
    (when (and entry (eql generation (plist-get entry :generation)))
      (while properties
        (setq entry (plist-put entry (pop properties) (pop properties))))
      (puthash agent entry lispm-kernel-desktop--cache))))

(defun lispm-kernel-desktop--arrived (agent generation sessions summary)
  "Keep AGENT's SESSIONS of GENERATION as SUMMARY says; tell the desktop."
  (when lispm-kernel-desktop-mode
    (let ((entry (gethash agent lispm-kernel-desktop--cache)))
      (when (and entry (eql generation (plist-get entry :generation)))
        (when (or (plist-get summary :error) (plist-get summary :native-error))
          (setq lispm-kernel-desktop-last-error summary))
        (if (plist-get summary :cancelled)
            (lispm-kernel-desktop--update agent generation :request nil)
          (lispm-kernel-desktop--update
           agent generation :request nil :time (float-time) :known t
           :sessions (if (plist-get summary :error) (plist-get entry :sessions) sessions))
          (lispm-desktop-agent-sessions-arrived))))))

(defun lispm-kernel-desktop--scan (agent)
  "Start a native scan of AGENT's current root in the background."
  (let* ((entry (gethash agent lispm-kernel-desktop--cache))
         (generation (plist-get entry :generation))
         (read (lispm-kernel-desktop--spec agent :read))
         (request (lispm-kernel-scan-sessions
                   lispm-kernel-desktop--runtime agent (plist-get entry :root)
                   (lambda (sessions summary)
                     (lispm-kernel-desktop--arrived agent generation sessions summary))
                   :owner (lispm-kernel-desktop--spec agent :owner) :generation generation
                   :timeout lispm-kernel-desktop-scan-timeout :fallback read)))
    (cond
     ((integerp request)
      (lispm-kernel-desktop--update agent generation :request request :started (float-time)))
     ((memq request '(busy capacity))
      ;; One bounded retry timer per agent; no synchronous retry loop.
      (lispm-kernel-desktop--update
       agent generation :request 'retry
       :retry-timer (run-at-time 0.05 nil #'lispm-kernel-desktop--retry agent generation)))
     (t
      ;; The module refuses this root for good: read it the desktop's way.
      (setq lispm-kernel-desktop-last-error request)
      (lispm-kernel-desktop--update agent generation :sessions (funcall read)
                                    :known t :time (float-time))))))

(defun lispm-kernel-desktop--retry (agent generation)
  "Retry AGENT's scan of GENERATION after busy admission."
  (when (and lispm-kernel-desktop-mode
             (lispm-kernel-desktop--update agent generation :request nil :retry-timer nil))
    (lispm-kernel-desktop--scan agent)))

(defun lispm-kernel-desktop--stale-p (entry)
  "Return non-nil when ENTRY needs a scan and none is under way."
  (let ((request (plist-get entry :request)))
    (and (or (null request)
             ;; A request whose final event never came is given up.
             (and (integerp request)
                  (> (- (float-time) (or (plist-get entry :started) 0))
                     (* 2 lispm-kernel-desktop-scan-timeout))))
         (or (null (plist-get entry :time))
             (> (- (float-time) (plist-get entry :time)) lispm-kernel-desktop-cache-seconds)))))

(defun lispm-kernel-desktop--read (agent)
  "Return AGENT's sessions as last scanned natively, or `pending' before that.
A missing or stale snapshot starts a scan in the background.  A remote or
missing root is read the desktop's own way."
  (let ((root (lispm-kernel-desktop--root agent)))
    (if (or (null lispm-kernel-desktop--runtime) (not (stringp root)) (file-remote-p root)
            (not (file-directory-p root)))
        (funcall (lispm-kernel-desktop--spec agent :read))
      (let ((entry (lispm-kernel-desktop--entry agent root)))
        (when (lispm-kernel-desktop--stale-p entry)
          (lispm-kernel-desktop--scan agent)
          (setq entry (gethash agent lispm-kernel-desktop--cache)))
        (if (plist-get entry :known)
            (copy-sequence (plist-get entry :sessions))
          'pending)))))

(defun lispm-kernel-desktop--root (agent)
  "Return the value of AGENT's root variable, or nil while it is unbound."
  (let ((variable (lispm-kernel-desktop--spec agent :root)))
    (and (boundp variable) (symbol-value variable))))

(defun lispm-kernel-desktop-invalidate ()
  "Read the sessions anew: supersede running scans, keep showing the old ones.
This is on `lispm-desktop-agent-reread-sessions-hook'."
  (when lispm-kernel-desktop--runtime
    (dolist (spec lispm-kernel-desktop--agents)
      (let* ((agent (car spec))
             (entry (gethash agent lispm-kernel-desktop--cache)))
        (when entry
          (let ((generation (1+ (plist-get entry :generation))))
            (lispm-kernel-desktop--forget-timer entry)
            (lispm-kernel-supersede lispm-kernel-desktop--runtime
                                    (plist-get (cdr spec) :owner) generation)
            (puthash agent (list :root (plist-get entry :root) :generation generation
                                 :sessions (plist-get entry :sessions)
                                 :known (plist-get entry :known))
                     lispm-kernel-desktop--cache)))))))

(defun lispm-kernel-desktop--enable ()
  "Start the runtime and register the session readers; signal when impossible."
  (require 'lispm-desktop-ai)
  (require 'lispm-desktop-agent-codex)
  (require 'lispm-desktop-agent-claude)
  (unless (and (fboundp 'lispm-desktop-agent-add-session-reader)
               (lispm-kernel-broker-available-p))
    (user-error "This LispM Desktop has no session readers or frame clock; update it"))
  (unless lispm-kernel-desktop--runtime
    (setq lispm-kernel-desktop--runtime
          (and (or (featurep 'lispm-kernel-module) lispm-kernel-desktop-module)
               (lispm-kernel-try-create lispm-kernel-desktop-module))))
  (unless lispm-kernel-desktop--runtime
    (setq lispm-kernel-desktop-last-error (or lispm-kernel-module-error 'module-unavailable))
    (user-error "No lispm-kernel module: %S" lispm-kernel-desktop-last-error))
  (unless (eq lispm-kernel-broker--runtime lispm-kernel-desktop--runtime)
    (lispm-kernel-broker-start lispm-kernel-desktop--runtime))
  (dolist (spec lispm-kernel-desktop--agents)
    (let ((agent (car spec)))
      (lispm-desktop-agent-add-session-reader
       agent (lambda () (lispm-kernel-desktop--read agent)))))
  (add-hook 'lispm-desktop-agent-reread-sessions-hook #'lispm-kernel-desktop-invalidate))

(defun lispm-kernel-desktop--disable ()
  "Give the sessions back to the desktop's own readers and close the runtime."
  (when (fboundp 'lispm-desktop-agent-remove-session-reader)
    (dolist (spec lispm-kernel-desktop--agents)
      (lispm-desktop-agent-remove-session-reader (car spec))))
  (remove-hook 'lispm-desktop-agent-reread-sessions-hook #'lispm-kernel-desktop-invalidate)
  (lispm-kernel-broker-stop)
  (when lispm-kernel-desktop--runtime (lispm-kernel-shutdown lispm-kernel-desktop--runtime))
  (setq lispm-kernel-desktop--runtime nil)
  (maphash (lambda (_ entry) (lispm-kernel-desktop--forget-timer entry))
           lispm-kernel-desktop--cache)
  (clrhash lispm-kernel-desktop--cache)
  (lispm-kernel-clear-session-cache)
  (when (fboundp 'lispm-desktop-agent-sessions-arrived)
    (lispm-desktop-agent-sessions-arrived)))

(define-minor-mode lispm-kernel-desktop-mode
  "Read Codex and Claude sessions for the agents sidebar in the background.
Needs a built lispm-kernel module (`lispm-kernel-desktop-module') and a LispM
Desktop with session readers and a frame clock; without them the mode stays
off and the desktop's own readers stay in use."
  :global t :group 'lispm-kernel
  (if (not lispm-kernel-desktop-mode)
      (lispm-kernel-desktop--disable)
    (condition-case error
        (lispm-kernel-desktop--enable)
      (error
       (setq lispm-kernel-desktop-mode nil)
       (lispm-kernel-desktop--disable)
       (signal (car error) (cdr error))))))

(defun lispm-kernel-desktop-unload-function ()
  "Give the sessions back to the desktop before `unload-feature' runs."
  (when lispm-kernel-desktop-mode (lispm-kernel-desktop-mode -1))
  nil)

(provide 'lispm-kernel-desktop)
;;; lispm-kernel-desktop.el ends here
