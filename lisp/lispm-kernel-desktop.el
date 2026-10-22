;;; lispm-kernel-desktop.el --- The desktop's sessions, read by the kernel -*- lexical-binding: t; -*-

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

;; Give LispM Desktop's agents sidebar the Codex and Claude sessions
;; without Emacs waiting for them.  `lispm-kernel-desktop-mode' registers
;; session readers with the desktop (`lispm-desktop-agent-add-session-reader'):
;; they answer with what the kernel read last, or `pending' before that,
;; and have it read again in the background once that is older than
;; `lispm-kernel-desktop-cache-seconds' or the sidebar reads sessions
;; anew.  Every other caller, the session picker among them, keeps the
;; desktop's own readers.  The kernel's messages are taken in on the
;; desktop's frame clock, see lispm-kernel-broker.el.  Nothing is advised.
;;
;; The program is the one `lispm-kernel-desktop-program' names, else the
;; one lispm-kernel-program.el downloads and checks, or builds when asked
;; to: until it is there the mode is on and the desktop's own readers
;; answer, and when it cannot be, the mode turns off, saying why.  A
;; kernel that exits is started again when a reader is next asked, unless
;; it ran shorter than `lispm-kernel-desktop-restart-seconds', and then
;; not until the mode is turned on anew; the desktop's own readers answer
;; meanwhile.

;;; Code:

(require 'lispm-kernel-sessions)
(require 'lispm-kernel-broker)
(require 'lispm-kernel-program)
(defvar lispm-desktop-agent-codex-sessions-directory)
(defvar lispm-desktop-agent-codex-index-file)
(defvar lispm-desktop-agent-claude-projects-directory)
(defvar lispm-desktop-agent-reread-sessions-hook)
(declare-function lispm-desktop-agent-add-session-reader "ext:lispm-desktop-ai" (agent reader))
(declare-function lispm-desktop-agent-remove-session-reader "ext:lispm-desktop-ai" (agent))
(declare-function lispm-desktop-agent-sessions-arrived "ext:lispm-desktop-ai" ())

(defcustom lispm-kernel-desktop-program nil
  "The kernel program to run, a file, or nil to have one got.
nil downloads the program of these sources in the background when none
is there, checked against the SHA-256 pinned with the Lisp, or builds it
when `lispm-kernel-program-source' says so, see
`lispm-kernel-program-obtain'; a file is run as it is, nothing being
downloaded or built."
  :type '(choice (const :tag "Downloaded, checked" nil) file) :group 'lispm-kernel)

(defcustom lispm-kernel-desktop-cache-seconds 2
  "Seconds what the kernel read is shown before a reader has it read again."
  :type 'number :group 'lispm-kernel)

(defcustom lispm-kernel-desktop-scan-timeout 60
  "Seconds the kernel may take reading before the desktop's own reader is used."
  :type 'number :group 'lispm-kernel)

(defcustom lispm-kernel-desktop-restart-seconds 10
  "A kernel that ran shorter than this before it exited is not started
again, until the mode is turned on anew."
  :type 'number :group 'lispm-kernel)

(defconst lispm-kernel-desktop--agents
  '((codex :owner 1 :root lispm-desktop-agent-codex-sessions-directory
           :index lispm-desktop-agent-codex-index-file
           :read lispm-desktop-agent-codex-sessions)
    (claude :owner 2 :root lispm-desktop-agent-claude-projects-directory
            :read lispm-desktop-agent-claude-sessions))
  "The agents read by the kernel: their owner, the variables naming their
root and index, and their own reader.")

(defvar lispm-kernel-desktop--runtime nil)

(defvar lispm-kernel-desktop--cache (make-hash-table :test #'eq)
  "Per agent, a plist (:root :generation :sessions :known :time :request
:started :retry-timer).  :known is non-nil once sessions were read, :time
is when, nil when they must be read anew.")

(defvar lispm-kernel-desktop-last-error nil
  "Why the kernel could not read sessions last, or nil.")

(defvar lispm-kernel-desktop-mode nil)

(defun lispm-kernel-desktop--spec (agent property)
  "Return PROPERTY of AGENT in `lispm-kernel-desktop--agents'."
  (plist-get (alist-get agent lispm-kernel-desktop--agents) property))

(defun lispm-kernel-desktop--value (agent property)
  "Return the value of the variable AGENT's PROPERTY names, nil while unbound."
  (let ((variable (lispm-kernel-desktop--spec agent property)))
    (and variable (boundp variable) (symbol-value variable))))

;;;; The kernel

(defun lispm-kernel-desktop--program ()
  "Return the program to run: `lispm-kernel-desktop-program', else the one
lispm-kernel-program.el has."
  (or lispm-kernel-desktop-program (lispm-kernel-program-file)))

(defun lispm-kernel-desktop--start-runtime (program)
  "Run PROGRAM as the desktop's kernel, its messages on the frame clock."
  (setq lispm-kernel-desktop--runtime (lispm-kernel-start program))
  (lispm-kernel-broker-start lispm-kernel-desktop--runtime))

(defun lispm-kernel-desktop--runtime ()
  "Return the desktop's kernel when it runs, starting it again once it exited,
unless it ran shorter than `lispm-kernel-desktop-restart-seconds'; else nil."
  (let ((runtime lispm-kernel-desktop--runtime))
    (cond ((null runtime) nil)
          ((lispm-kernel-live-p runtime) runtime)
          ((< (- (or (lispm-kernel-runtime-exited-at runtime) (float-time))
                 (lispm-kernel-runtime-started runtime))
              lispm-kernel-desktop-restart-seconds)
           (setq lispm-kernel-desktop-last-error
                 (or (lispm-kernel-runtime-last-error runtime) (lispm-kernel-runtime-exited runtime)))
           nil)
          (t
           (setq lispm-kernel-desktop-last-error
                 (or (lispm-kernel-runtime-last-error runtime) (lispm-kernel-runtime-exited runtime)))
           (lispm-kernel-broker-stop)
           (lispm-kernel-stop runtime)
           (condition-case error
               (progn
                 ;; What the old one read is gone with it: read everything anew.
                 (maphash (lambda (_ entry)
                            (lispm-kernel-desktop--forget-timer entry))
                          lispm-kernel-desktop--cache)
                 (clrhash lispm-kernel-desktop--cache)
                 (lispm-kernel-desktop--start-runtime (lispm-kernel-desktop--program))
                 lispm-kernel-desktop--runtime)
             (error (setq lispm-kernel-desktop-last-error error)
                    nil))))))

;;;; Reading

(defun lispm-kernel-desktop--forget-timer (entry)
  "Cancel ENTRY's retry."
  (when-let* ((timer (plist-get entry :retry-timer)))
    (cancel-timer timer)))

(defun lispm-kernel-desktop--entry (runtime agent root)
  "Return AGENT's cache entry for ROOT; a new ROOT starts a new generation."
  (let ((entry (gethash agent lispm-kernel-desktop--cache)))
    (unless (and entry (equal root (plist-get entry :root)))
      (let ((generation (1+ (or (plist-get entry :generation) 0))))
        (when entry
          (lispm-kernel-desktop--forget-timer entry)
          (lispm-kernel-supersede runtime (lispm-kernel-desktop--spec agent :owner) generation))
        (setq entry (list :root root :generation generation))
        (puthash agent entry lispm-kernel-desktop--cache)))
    entry))

(defun lispm-kernel-desktop--update (agent generation &rest properties)
  "Set PROPERTIES of AGENT's entry while its generation is GENERATION.
Return the entry, or nil when its generation has moved on."
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
        (cond
         ((plist-get summary :cancelled)
          (lispm-kernel-desktop--update agent generation :request nil))
         ((eq (plist-get summary :rejected) 'capacity)
          ;; One retry timer per agent; no retry within this call.
          (lispm-kernel-desktop--update
           agent generation :request 'retry
           :retry-timer (run-at-time 0.05 nil #'lispm-kernel-desktop--retry agent generation)))
         ((plist-get summary :rejected)
          (lispm-kernel-desktop--update agent generation :request nil))
         (t
          (lispm-kernel-desktop--update
           agent generation :request nil :time (float-time) :known t
           :sessions (if (plist-get summary :error) (plist-get entry :sessions) sessions))
          (lispm-desktop-agent-sessions-arrived)))))))

(defun lispm-kernel-desktop--scan (runtime agent)
  "Have RUNTIME's kernel read AGENT's sessions in the background."
  (let* ((entry (gethash agent lispm-kernel-desktop--cache))
         (generation (plist-get entry :generation))
         (request (lispm-kernel-scan-sessions
                   runtime agent (plist-get entry :root)
                   (lambda (sessions summary)
                     (lispm-kernel-desktop--arrived agent generation sessions summary))
                   :owner (lispm-kernel-desktop--spec agent :owner) :generation generation
                   :index (let ((index (lispm-kernel-desktop--value agent :index)))
                            (and (stringp index) (not (file-remote-p index)) index))
                   :timeout lispm-kernel-desktop-scan-timeout
                   :fallback (lispm-kernel-desktop--spec agent :read))))
    (lispm-kernel-desktop--update agent generation :request (or request 'fallback)
                                  :started (float-time))))

(defun lispm-kernel-desktop--retry (agent generation)
  "Have AGENT's sessions of GENERATION read again after the kernel was full."
  (when (and lispm-kernel-desktop-mode
             (lispm-kernel-desktop--update agent generation :request nil :retry-timer nil))
    (when-let* ((runtime (lispm-kernel-desktop--runtime)))
      (lispm-kernel-desktop--scan runtime agent))))

(defun lispm-kernel-desktop--stale-p (entry)
  "Return non-nil when ENTRY must be read anew and no reading is under way."
  (let ((request (plist-get entry :request)))
    (and (or (null request)
             ;; A reading whose answer never came is given up.
             (and (not (eq request 'retry))
                  (> (- (float-time) (or (plist-get entry :started) 0))
                     (* 2 lispm-kernel-desktop-scan-timeout))))
         (or (null (plist-get entry :time))
             (> (- (float-time) (plist-get entry :time)) lispm-kernel-desktop-cache-seconds)))))

(defun lispm-kernel-desktop--read (agent)
  "Return AGENT's sessions as the kernel read them last, or `pending' before.
A missing or stale reading starts another in the background.  A remote or
missing root, or no kernel running, is read the desktop's own way."
  (let ((root (lispm-kernel-desktop--value agent :root))
        (runtime (lispm-kernel-desktop--runtime)))
    (if (or (null runtime) (not (stringp root)) (file-remote-p root) (not (file-directory-p root)))
        (funcall (lispm-kernel-desktop--spec agent :read))
      (let ((entry (lispm-kernel-desktop--entry runtime agent root)))
        (when (lispm-kernel-desktop--stale-p entry)
          (lispm-kernel-desktop--scan runtime agent)
          (setq entry (gethash agent lispm-kernel-desktop--cache)))
        (if (plist-get entry :known)
            (copy-sequence (plist-get entry :sessions))
          'pending)))))

(defun lispm-kernel-desktop-invalidate ()
  "Read the sessions anew: supersede readings under way, keep showing the old.
This is on `lispm-desktop-agent-reread-sessions-hook'."
  (when-let* ((runtime lispm-kernel-desktop--runtime))
    (dolist (spec lispm-kernel-desktop--agents)
      (let* ((agent (car spec))
             (entry (gethash agent lispm-kernel-desktop--cache)))
        (when entry
          (let ((generation (1+ (plist-get entry :generation))))
            (lispm-kernel-desktop--forget-timer entry)
            (lispm-kernel-supersede runtime (plist-get (cdr spec) :owner) generation)
            (puthash agent (list :root (plist-get entry :root) :generation generation
                                 :sessions (plist-get entry :sessions)
                                 :known (plist-get entry :known))
                     lispm-kernel-desktop--cache)))))))

;;;; The mode

(defun lispm-kernel-desktop--start ()
  "Start the kernel and register the session readers."
  (unless lispm-kernel-desktop--runtime
    (lispm-kernel-desktop--start-runtime (lispm-kernel-desktop--program)))
  (dolist (spec lispm-kernel-desktop--agents)
    (let ((agent (car spec)))
      (lispm-desktop-agent-add-session-reader
       agent (lambda () (lispm-kernel-desktop--read agent)))))
  (add-hook 'lispm-desktop-agent-reread-sessions-hook #'lispm-kernel-desktop-invalidate))

(defun lispm-kernel-desktop--unavailable ()
  "Signal that no program can be had, saying why."
  (setq lispm-kernel-desktop-last-error (or lispm-kernel-program-problem 'program-unavailable))
  (user-error "No lispm-kernel program, so the desktop reads sessions itself: %s"
              (or lispm-kernel-program-problem "none is there")))

(defun lispm-kernel-desktop--obtained (there)
  "Finish turning the mode on now that the program is THERE, or turn it off.
This is on `lispm-kernel-program-obtained-functions' while the mode waits
for the program."
  (remove-hook 'lispm-kernel-program-obtained-functions #'lispm-kernel-desktop--obtained)
  (when (and lispm-kernel-desktop-mode (not lispm-kernel-desktop--runtime))
    (condition-case error
        (if there (lispm-kernel-desktop--start) (lispm-kernel-desktop--unavailable))
      (error
       (lispm-kernel-desktop-mode -1)
       (message "%s" (error-message-string error))))))

(defun lispm-kernel-desktop--enable ()
  "Start the kernel and register the session readers, now, or once the
program is built or downloaded; signal when impossible."
  (require 'lispm-desktop-ai)
  (require 'lispm-desktop-agent-codex)
  (require 'lispm-desktop-agent-claude)
  (unless (and (fboundp 'lispm-desktop-agent-add-session-reader)
               (lispm-kernel-broker-available-p))
    (user-error "This LispM Desktop has no session readers or frame clock; update it"))
  (if (or lispm-kernel-desktop--runtime lispm-kernel-desktop-program)
      (lispm-kernel-desktop--start)
    (pcase (lispm-kernel-program-obtain)
      ('ready (lispm-kernel-desktop--start))
      ;; Until it is there, the desktop's own readers answer.
      ('pending (add-hook 'lispm-kernel-program-obtained-functions #'lispm-kernel-desktop--obtained))
      (_ (lispm-kernel-desktop--unavailable)))))

(defun lispm-kernel-desktop--disable ()
  "Give the sessions back to the desktop's own readers and stop the kernel."
  (remove-hook 'lispm-kernel-program-obtained-functions #'lispm-kernel-desktop--obtained)
  (when (fboundp 'lispm-desktop-agent-remove-session-reader)
    (dolist (spec lispm-kernel-desktop--agents)
      (lispm-desktop-agent-remove-session-reader (car spec))))
  (remove-hook 'lispm-desktop-agent-reread-sessions-hook #'lispm-kernel-desktop-invalidate)
  (lispm-kernel-broker-stop)
  (when lispm-kernel-desktop--runtime
    (lispm-kernel-stop lispm-kernel-desktop--runtime))
  (setq lispm-kernel-desktop--runtime nil)
  (maphash (lambda (_ entry) (lispm-kernel-desktop--forget-timer entry))
           lispm-kernel-desktop--cache)
  (clrhash lispm-kernel-desktop--cache)
  (when (fboundp 'lispm-desktop-agent-sessions-arrived)
    (lispm-desktop-agent-sessions-arrived)))

(define-minor-mode lispm-kernel-desktop-mode
  "Read Codex and Claude sessions for the agents sidebar in the background.
Needs a LispM Desktop with session readers and a frame clock, and the
kernel program: the one `lispm-kernel-desktop-program' names, else the
one downloaded for these sources and checked against the SHA-256 pinned
with the Lisp, or built with SBCL when `lispm-kernel-program-source' says
so, in the background, see `lispm-kernel-program-obtain'.  Until that is
there the desktop's own readers answer; without a desktop or a program
to be had, the mode turns off, saying why, and they stay in use."
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
