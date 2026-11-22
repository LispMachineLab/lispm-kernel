;;; lispm-kernel-desktop.el --- The agents' sessions, read by the kernel -*- lexical-binding: t; -*-

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

;; Give the editor's agents (lispm-agents, of lispm-agent) the Codex and
;; Claude sessions without Emacs waiting for them.
;; `lispm-kernel-sessions-mode' registers session readers with them
;; (`lispm-agents-add-session-reader'): they answer with what the kernel
;; read last, or `pending' before that, and have it read again in the
;; background once that is older than `lispm-kernel-desktop-cache-seconds'
;; or the agents' list reads sessions anew.  The kernel also tells whether
;; each session's latest turn has ended (:turn-ended), and what it read
;; answers:
;;
;; - looking a session up, as for a terminal waiting to be given a
;;   message (`lispm-agents-session-lookup-functions'), reading again
;;   when it is stale but never waiting, nor reading itself;
;; - the list of every session a terminal or session picker reads
;;   (`lispm-agents-read-sessions-function'), answered immediately from
;;   what the kernel read last (or nil while the initial background scan
;;   runs), `lispm-agents-sessions-arrived' telling when newer sessions
;;   arrive, never blocking Emacs's thread.
;;
;; The kernel's messages are taken in by timers, or by the host's
;; `lispm-kernel-scheduler', as LispM Desktop's frame clock.  Nothing is
;; advised but that function variable, which is there for it.  The
;; library keeps its name, and its options theirs, from when LispM
;; Desktop held the agents.
;;
;; The program is the one `lispm-kernel-desktop-program' names, else the
;; one lispm-kernel-program.el downloads and checks, or builds when asked
;; to: until it is there the mode is on and the agents' own readers
;; answer, and when it cannot be, the mode turns off, saying why.  A
;; kernel that exits is started again when a reader is next asked; one
;; that ran shorter than `lispm-kernel-desktop-restart-seconds' only after
;; a while, longer each time it does so again, see
;; `lispm-kernel-desktop-restart-limit', and the agents' own readers
;; answer meanwhile.  `lispm-kernel-desktop-restart' starts it again at
;; once, and `lispm-kernel-desktop-status' says how it stands, for a
;; control panel.

;;; Code:

(require 'lispm-kernel-sessions)
(require 'lispm-kernel-program)
(defvar lispm-agents-codex-sessions-directory)
(defvar lispm-agents-codex-index-file)
(defvar lispm-agents-claude-projects-directory)
(defvar lispm-agents-reread-sessions-hook)
(defvar lispm-agents-read-sessions-function)
(declare-function lispm-agents-add-session-reader "ext:lispm-agents" (agent reader))
(declare-function lispm-agents-remove-session-reader "ext:lispm-agents" (agent))
(declare-function lispm-agents-sessions-arrived "ext:lispm-agents" ())

(define-error 'lispm-kernel-desktop-error "LispM kernel desktop error" 'lispm-kernel-error)

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

(defcustom lispm-kernel-desktop-wait-seconds 0
  "Obsolete; session lookups are strictly asynchronous and never wait."
  :type 'number :group 'lispm-kernel)
(make-obsolete-variable
 'lispm-kernel-desktop-wait-seconds
 "Session reads are strictly non-blocking and never wait on the main thread."
 "0.9.0")

(defcustom lispm-kernel-desktop-scan-timeout 60
  "Seconds the kernel may take reading before the agents' own reader is used."
  :type 'number :group 'lispm-kernel)

(defcustom lispm-kernel-desktop-restart-seconds 10
  "Minimum uptime in seconds before an exited kernel restarts immediately.
A kernel exiting sooner waits this many seconds, doubling on consecutive
early exits up to `lispm-kernel-desktop-restart-limit'."
  :type 'number :group 'lispm-kernel)

(defcustom lispm-kernel-desktop-restart-limit 600
  "Maximum backoff seconds before restarting a repeatedly exiting kernel.
See `lispm-kernel-desktop-restart-seconds'."
  :type 'number :group 'lispm-kernel)

(defconst lispm-kernel-desktop--agents
  '((codex :owner 1 :root lispm-agents-codex-sessions-directory
           :index lispm-agents-codex-index-file
           :read lispm-agents-codex-sessions)
    (claude :owner 2 :root lispm-agents-claude-projects-directory
            :read lispm-agents-claude-sessions))
  "Specifications of agents whose sessions are read by the kernel.
Each entry maps an agent symbol to its owner id, root/index variables and
fallback reader.")

(defvar lispm-kernel-desktop--runtime nil
  "The local kernel runtime managed by `lispm-kernel-sessions-mode'.")

(defcustom lispm-kernel-desktop-remote-hosts t
  "Non-nil to stage and run a kernel on each single-hop SSH host accessed."
  :type 'boolean :group 'lispm-kernel)

(defvar lispm-kernel-desktop--hosts (make-hash-table :test #'equal)
  "State table of remote kernel runtimes keyed by SSH TRAMP prefix.
Each value has `:runtime', `:staging', `:early-exits', `:restart-at' and
`:last-error'.")

(defvar lispm-kernel-desktop-host-command-function nil
  "Optional function returning the kernel command for a remote SSH host.
Called with HOST (a TRAMP prefix); returns a command or nil to stage over SSH.")

(defvar lispm-kernel-desktop--cache (make-hash-table :test #'equal)
  "Cached session scans keyed by AGENT locally or `(AGENT . HOST)' remotely.
Each value is a plist `(:root :generation :sessions :known :time :turns
:request :started :retry-timer)'.")

(defvar lispm-kernel-desktop-last-error nil
  "Why the kernel could not read sessions last, or nil.")

(defvar lispm-kernel-desktop--early-exits 0
  "Consecutive local kernel exits before `lispm-kernel-desktop-restart-seconds'.")

(defvar lispm-kernel-desktop--restart-at nil
  "Next `float-time' when an exited local kernel may restart, or nil.")

;; The mode's name of when LispM Desktop held the agents.
(define-obsolete-variable-alias 'lispm-kernel-desktop-mode 'lispm-kernel-sessions-mode "0.4.0")
(defvar lispm-kernel-sessions-mode nil)

(defun lispm-kernel-desktop--spec (agent property)
  "Return PROPERTY of AGENT in `lispm-kernel-desktop--agents'."
  (plist-get (alist-get agent lispm-kernel-desktop--agents) property))

(defun lispm-kernel-desktop--value (agent property)
  "Return the value of the variable AGENT's PROPERTY names, nil while unbound."
  (let ((variable (lispm-kernel-desktop--spec agent property)))
    (and variable (boundp variable) (symbol-value variable))))

;;;; The kernel

(defun lispm-kernel-desktop--program ()
  "Return the kernel program path to run, or nil when unavailable.
Prefers `lispm-kernel-desktop-program', else `lispm-kernel-program-file'."
  (or lispm-kernel-desktop-program (lispm-kernel-program-file)))

(defun lispm-kernel-desktop--start-runtime (program)
  "Run PROGRAM as the agents' kernel."
  (setq lispm-kernel-desktop--runtime (lispm-kernel-start program)))

(defun lispm-kernel-desktop--restart-delay ()
  "Return backoff seconds before restarting an early-exiting local kernel.
Scales exponentially with `lispm-kernel-desktop--early-exits'."
  (min lispm-kernel-desktop-restart-limit
       (* lispm-kernel-desktop-restart-seconds
          (expt 2 (min 30 (max 0 (1- lispm-kernel-desktop--early-exits)))))))

(defun lispm-kernel-desktop--clear-local-cache ()
  "Cancel timers and remove local entries in `lispm-kernel-desktop--cache'."
  (let (local-keys)
    (maphash (lambda (key entry)
               (unless (consp key)
                 (lispm-kernel-desktop--forget-timer entry)
                 (push key local-keys)))
             lispm-kernel-desktop--cache)
    (dolist (key local-keys)
      (remhash key lispm-kernel-desktop--cache))))

(defun lispm-kernel-desktop--start-again ()
  "Stop any local kernel, clear its cached scans, and start a fresh runtime.
Return the new runtime, or nil on failure while recording
`lispm-kernel-desktop-last-error'."
  (when lispm-kernel-desktop--runtime
    (lispm-kernel-stop lispm-kernel-desktop--runtime))
  (condition-case error
      (progn
        ;; What the old one read is gone with it: read local roots anew.
        (lispm-kernel-desktop--clear-local-cache)
        (lispm-kernel-desktop--start-runtime
         (or (lispm-kernel-desktop--program)
             (signal 'lispm-kernel-desktop-error '("No lispm-kernel program is there"))))
        (setq lispm-kernel-desktop--restart-at nil)
        lispm-kernel-desktop--runtime)
    (error (setq lispm-kernel-desktop-last-error error
                 lispm-kernel-desktop--restart-at (+ (float-time) lispm-kernel-desktop-restart-seconds))
           nil)))

(defun lispm-kernel-desktop--runtime ()
  "Return the running local kernel runtime, restarting it when due, or nil.
Early exits respect `lispm-kernel-desktop--restart-delay'."
  (let ((runtime lispm-kernel-desktop--runtime))
    (cond ((null runtime) nil)
          ((lispm-kernel-live-p runtime) runtime)
          (t
           (unless lispm-kernel-desktop--restart-at
             ;; Its exit, seen for the first time.
             (let* ((exited (or (lispm-kernel-runtime-exited-at runtime) (float-time)))
                    (early (< (- exited (lispm-kernel-runtime-started runtime))
                              lispm-kernel-desktop-restart-seconds)))
               (setq lispm-kernel-desktop-last-error (lispm-kernel-why-not-running runtime)
                     lispm-kernel-desktop--early-exits (if early (1+ lispm-kernel-desktop--early-exits) 0)
                     lispm-kernel-desktop--restart-at
                     (if early (+ exited (lispm-kernel-desktop--restart-delay)) exited))))
           (when (>= (float-time) lispm-kernel-desktop--restart-at)
             (lispm-kernel-desktop--start-again))))))

(defun lispm-kernel-desktop-restart ()
  "Start the agents' kernel again at once, its program as it is now.
A kernel that keeps exiting is tried again; while the program is being
downloaded or built, it starts once that is done."
  (interactive)
  (unless lispm-kernel-sessions-mode
    (user-error "Mode `lispm-kernel-sessions-mode' is off"))
  (setq lispm-kernel-desktop--early-exits 0)
  (cond (lispm-kernel-desktop--runtime
         (unless (lispm-kernel-desktop--start-again)
           (user-error "The kernel could not be started: %s"
                       (lispm-kernel-desktop--why lispm-kernel-desktop-last-error))))
        ((lispm-kernel-program-busy-p)
         (message "The kernel starts once its program is there"))
        (t (lispm-kernel-desktop--enable))))

(defun lispm-kernel-desktop--why (error)
  "Return ERROR, a sentence, an error or a summary, as a sentence."
  (cond ((stringp error) error)
        ((and (consp error) (symbolp (car error)) (get (car error) 'error-conditions))
         (error-message-string error))
        (t (format "%s" error))))

(defun lispm-kernel-desktop-status ()
  "Return the status form of the agents' kernel for UI panels.
Possible values are `(off)', `(getting FRACTION)', `(running PROCESS SINCE)',
or `(exited WHY AT)'."
  (let ((runtime lispm-kernel-desktop--runtime))
    (cond ((not lispm-kernel-sessions-mode) '(off))
          ((and runtime (lispm-kernel-live-p runtime))
           (list 'running (lispm-kernel-runtime-process runtime) (lispm-kernel-runtime-started runtime)))
          (runtime
           ;; Seen as a reader would see it.
           (unless lispm-kernel-desktop--restart-at
             (lispm-kernel-desktop--runtime))
           (if (and lispm-kernel-desktop--runtime (lispm-kernel-live-p lispm-kernel-desktop--runtime))
               (lispm-kernel-desktop-status)
             (list 'exited (lispm-kernel-desktop--why lispm-kernel-desktop-last-error)
                   (or lispm-kernel-desktop--restart-at (float-time)))))
          (t (list 'getting (and (lispm-kernel-program-busy-p) lispm-kernel-program-progress))))))

(defun lispm-kernel-desktop--host-delay (early-exits)
  "Return backoff seconds for a host kernel with EARLY-EXITS in a row."
  (min lispm-kernel-desktop-restart-limit
       (* lispm-kernel-desktop-restart-seconds
          (expt 2 (min 30 (max 0 (1- early-exits)))))))

(defun lispm-kernel-desktop--clear-host-cache (host)
  "Cancel retry timers and remove cached scans belonging to remote SSH HOST."
  (let (host-keys)
    (maphash (lambda (key entry)
               (when (and (consp key) (equal (cdr key) host))
                 (lispm-kernel-desktop--forget-timer entry)
                 (push key host-keys)))
             lispm-kernel-desktop--cache)
    (dolist (key host-keys)
      (remhash key lispm-kernel-desktop--cache))))

(defun lispm-kernel-desktop--start-host (host command)
  "Start a kernel for remote SSH HOST using COMMAND and store it."
  (let* ((state (gethash host lispm-kernel-desktop--hosts))
         (old (plist-get state :runtime)))
    (when old
      (lispm-kernel-stop old)
      (lispm-kernel-desktop--clear-host-cache host))
    (condition-case err
        (let ((runtime (lispm-kernel-start command host)))
          (puthash host (list :runtime runtime :staging nil
                              :early-exits (or (plist-get state :early-exits) 0)
                              :restart-at nil :last-error nil)
                   lispm-kernel-desktop--hosts)
          (when (fboundp 'lispm-agents-sessions-arrived)
            (lispm-agents-sessions-arrived))
          runtime)
      (error
       (let ((exits (1+ (or (plist-get state :early-exits) 0))))
         (puthash host (list :runtime nil :staging nil
                             :early-exits exits
                             :restart-at (+ (float-time) (lispm-kernel-desktop--host-delay exits))
                             :last-error err)
                  lispm-kernel-desktop--hosts)
         nil)))))

(defun lispm-kernel-desktop--host-runtime (host)
  "Return the running kernel for SSH HOST, starting or staging it if needed."
  (when (and host (lispm-kernel-ssh-host host))
    (let* ((state (gethash host lispm-kernel-desktop--hosts))
           (runtime (plist-get state :runtime)))
      (cond
       ((and runtime (lispm-kernel-live-p runtime))
        runtime)
       ((plist-get state :staging)
        nil)
       (t
        (when (and runtime (not (plist-get state :restart-at)))
          (let* ((exited (or (lispm-kernel-runtime-exited-at runtime) (float-time)))
                 (early (< (- exited (lispm-kernel-runtime-started runtime))
                           lispm-kernel-desktop-restart-seconds))
                 (exits (if early (1+ (or (plist-get state :early-exits) 0)) 0)))
            (setq state (list :runtime runtime :staging nil
                              :early-exits exits
                              :restart-at (if early (+ exited (lispm-kernel-desktop--host-delay exits)) exited)
                              :last-error (lispm-kernel-why-not-running runtime)))
            (puthash host state lispm-kernel-desktop--hosts)))
        (when (or (null (plist-get state :restart-at))
                  (>= (float-time) (plist-get state :restart-at)))
          (cond
           ((when-let* ((command (and lispm-kernel-desktop-host-command-function
                                      (funcall lispm-kernel-desktop-host-command-function host))))
              (lispm-kernel-desktop--start-host host command)))
           ((and lispm-kernel-desktop-remote-hosts
                 (null lispm-kernel-desktop-program))
            (puthash host (plist-put (copy-sequence state) :staging t)
                     lispm-kernel-desktop--hosts)
            (lispm-kernel-program-stage-ssh
             host
             (lambda (command problem)
               (if (not (and lispm-kernel-sessions-mode command))
                   (let ((exits (1+ (or (plist-get state :early-exits) 0))))
                     (puthash host (list :runtime nil :staging nil
                                         :early-exits exits
                                         :restart-at (+ (float-time)
                                                        (lispm-kernel-desktop--host-delay exits))
                                         :last-error (or problem "staging failed"))
                              lispm-kernel-desktop--hosts))
                 (lispm-kernel-desktop--start-host host command))))
            nil))))))))

(defun lispm-kernel-desktop--root-runtime (root &optional check-mode)
  "Return the running kernel for ROOT, or nil when none runs for its host.
When CHECK-MODE is non-nil, require `lispm-kernel-sessions-mode' to be enabled."
  (when (and (stringp root)
             (or (file-remote-p root) (file-directory-p root)))
    (if check-mode
        (lispm-kernel-desktop-runtime root)
      (if (file-remote-p root)
          (lispm-kernel-desktop--host-runtime (lispm-kernel-ssh-host root))
        (lispm-kernel-desktop--runtime)))))

(defun lispm-kernel-desktop-runtime (&optional directory)
  "Return the running kernel for DIRECTORY when `lispm-kernel-sessions-mode' is on.
Restarts an exited kernel according to the mode's backoff schedule."
  (and lispm-kernel-sessions-mode
       (if (and (stringp directory) (file-remote-p directory))
           (lispm-kernel-desktop--host-runtime (lispm-kernel-ssh-host directory))
         (lispm-kernel-desktop--runtime))))

;;;; Reading

(defun lispm-kernel-desktop--cache-key (agent &optional root)
  "Return the cache key for AGENT at ROOT.
Local roots key directly on AGENT; remote SSH roots key on `(AGENT . HOST)'."
  (if-let* ((host (and (stringp root) (lispm-kernel-ssh-host root))))
      (cons agent host)
    agent))

(defun lispm-kernel-desktop--key-agent (key)
  "Return the agent symbol encoded in cache KEY."
  (if (consp key) (car key) key))

(defun lispm-kernel-desktop--forget-timer (entry)
  "Cancel ENTRY's retry."
  (when-let* ((timer (plist-get entry :retry-timer)))
    (cancel-timer timer)))

(defun lispm-kernel-desktop--entry (runtime agent root)
  "Return AGENT's cache entry on RUNTIME for ROOT, advancing generation on change."
  (let* ((key (lispm-kernel-desktop--cache-key agent root))
         (entry (gethash key lispm-kernel-desktop--cache)))
    (unless (and entry (equal root (plist-get entry :root)))
      (let ((generation (1+ (or (plist-get entry :generation) 0))))
        (when entry
          (lispm-kernel-desktop--forget-timer entry)
          (lispm-kernel-supersede runtime (lispm-kernel-desktop--spec agent :owner) generation))
        (setq entry (list :root root :generation generation))
        (puthash key entry lispm-kernel-desktop--cache)))
    entry))

(defun lispm-kernel-desktop--update (key generation &rest properties)
  "Set PROPERTIES on cache entry KEY while its generation equals GENERATION.
Return the updated entry, or nil when its generation has moved on."
  (let ((entry (gethash key lispm-kernel-desktop--cache)))
    (when (and entry (eql generation (plist-get entry :generation)))
      (while properties
        (setq entry (plist-put entry (pop properties) (pop properties))))
      (puthash key entry lispm-kernel-desktop--cache))))

(defun lispm-kernel-desktop--arrived (key generation sessions summary)
  "Record SESSIONS and SUMMARY for cache KEY at GENERATION and notify listeners."
  (when lispm-kernel-sessions-mode
    (let ((entry (gethash key lispm-kernel-desktop--cache)))
      (when (and entry (eql generation (plist-get entry :generation)))
        (when (or (plist-get summary :error) (plist-get summary :native-error))
          (setq lispm-kernel-desktop-last-error summary))
        (cond
         ((plist-get summary :cancelled)
          (lispm-kernel-desktop--update key generation :request nil))
         ((eq (plist-get summary :rejected) 'capacity)
          ;; One retry timer per cache key; no retry within this call.
          (lispm-kernel-desktop--update
           key generation :request 'retry
           :retry-timer (run-at-time 0.05 nil #'lispm-kernel-desktop--retry key generation)))
         ((plist-get summary :rejected)
          (lispm-kernel-desktop--update key generation :request nil))
         (t
          (let ((known (plist-get entry :known))
                (old (plist-get entry :sessions))
                (sessions (if (plist-get summary :error) (plist-get entry :sessions) sessions)))
            (lispm-kernel-desktop--update
             key generation :request nil :time (float-time) :known t
             :turns (plist-get summary :turn-ended) :sessions sessions)
            ;; Read again as they were, they need not be drawn again.
            (unless (and known (equal sessions old))
              (lispm-agents-sessions-arrived)))))))))

(defun lispm-kernel-desktop--scan (runtime agent &optional root)
  "Start a background session scan on RUNTIME for AGENT under ROOT."
  (let* ((root (or root (lispm-kernel-desktop--value agent :root)))
         (key (lispm-kernel-desktop--cache-key agent root))
         (entry (gethash key lispm-kernel-desktop--cache))
         (generation (plist-get entry :generation))
         (settled nil)
         (_ (lispm-kernel-desktop--update key generation :request 'starting
                                          :started (float-time)))
         (request (lispm-kernel-scan-sessions
                   runtime agent (plist-get entry :root)
                   (lambda (sessions summary)
                     (setq settled t)
                     (lispm-kernel-desktop--arrived key generation sessions summary))
                   :owner (lispm-kernel-desktop--spec agent :owner) :generation generation
                   :index (let ((index (lispm-kernel-desktop--value agent :index)))
                            (and (stringp index) (lispm-kernel-same-host-p runtime index) index))
                   :timeout lispm-kernel-desktop-scan-timeout
                   :fallback (lispm-kernel-desktop--spec agent :read))))
    (unless settled
      (lispm-kernel-desktop--update key generation :request (or request 'fallback)))))

(defun lispm-kernel-desktop--retry (key generation)
  "Retry scanning cache KEY at GENERATION after a capacity rejection."
  (when (and lispm-kernel-sessions-mode
             (lispm-kernel-desktop--update key generation :request nil :retry-timer nil))
    (let* ((entry (gethash key lispm-kernel-desktop--cache))
           (agent (lispm-kernel-desktop--key-agent key))
           (root (or (plist-get entry :root) (lispm-kernel-desktop--value agent :root))))
      (when-let* ((runtime (and root (lispm-kernel-desktop--root-runtime root))))
        (lispm-kernel-desktop--scan runtime agent root)))))

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
A missing or stale reading starts another in the background.  A missing
root, or no kernel running for its host, is read the agents' own way."
  (let* ((root (lispm-kernel-desktop--value agent :root))
         (key (lispm-kernel-desktop--cache-key agent root))
         (runtime (lispm-kernel-desktop--root-runtime root)))
    (if (null runtime)
        (funcall (lispm-kernel-desktop--spec agent :read))
      (let ((entry (lispm-kernel-desktop--entry runtime agent root)))
        (when (lispm-kernel-desktop--stale-p entry)
          (lispm-kernel-desktop--scan runtime agent root)
          (setq entry (gethash key lispm-kernel-desktop--cache)))
        (if (plist-get entry :known)
            (copy-sequence (plist-get entry :sessions))
          'pending)))))

(defun lispm-kernel-desktop--read-lately (agent)
  "Return AGENT's cached entry of any age, `pending' before first scan, or nil.
Triggers a background refresh when the cached entry is stale."
  (let* ((root (lispm-kernel-desktop--value agent :root))
         (key (lispm-kernel-desktop--cache-key agent root))
         (runtime (lispm-kernel-desktop--root-runtime root t)))
    (when runtime
      (let ((entry (lispm-kernel-desktop--entry runtime agent root)))
        (when (lispm-kernel-desktop--stale-p entry)
          (lispm-kernel-desktop--scan runtime agent root)
          (setq entry (gethash key lispm-kernel-desktop--cache)))
        (cond
         ((and (plist-get entry :known) (plist-get entry :turns)) entry)
         ((not (plist-get entry :known)) 'pending)
         (t nil))))))

(defun lispm-kernel-desktop--current (read agent sessions &optional recent)
  "Return AGENT's cached sessions, else fall back to READ with SESSIONS.
Never blocks Emacs waiting on the kernel: returns the latest cached scan
\(triggering a background refresh when stale) or nil while the initial scan
is pending.  Calls READ with RECENT only when no eligible kernel runs."
  (pcase (and (assq agent lispm-kernel-desktop--agents)
              (lispm-kernel-desktop--read-lately agent))
    ('pending nil)
    ('nil (funcall read agent sessions recent))
    (entry (copy-sequence (plist-get entry :sessions)))))

(defun lispm-kernel-desktop--lookup (agent id)
  "Return AGENT's session ID as the kernel read it last, or nil.
A stale reading starts another; none is waited for, nor read the
agents' own way.  This is on `lispm-agents-session-lookup-functions'."
  (when (assq agent lispm-kernel-desktop--agents)
    (let ((entry (lispm-kernel-desktop--read-lately agent)))
      (when (consp entry)
        (seq-find (lambda (session) (equal (plist-get session :id) id))
                  (plist-get entry :sessions))))))

(defun lispm-kernel-desktop-invalidate ()
  "Read the sessions anew: supersede readings under way, keep showing the old.
This is on `lispm-agents-reread-sessions-hook'."
  (let (keys)
    (maphash (lambda (key _) (push key keys)) lispm-kernel-desktop--cache)
    (dolist (key keys)
      (let* ((entry (gethash key lispm-kernel-desktop--cache))
             (agent (lispm-kernel-desktop--key-agent key))
             (owner (lispm-kernel-desktop--spec agent :owner))
             (root (and entry (plist-get entry :root)))
             (runtime (and root
                           (if (file-remote-p root)
                               (plist-get (gethash (lispm-kernel-ssh-host root)
                                                   lispm-kernel-desktop--hosts)
                                          :runtime)
                             lispm-kernel-desktop--runtime))))
        (when (and entry owner)
          (let ((generation (1+ (plist-get entry :generation))))
            (lispm-kernel-desktop--forget-timer entry)
            (when runtime
              (lispm-kernel-supersede runtime owner generation))
            (puthash key (list :root root :generation generation
                               :sessions (plist-get entry :sessions)
                               :turns (plist-get entry :turns)
                               :known (plist-get entry :known))
                     lispm-kernel-desktop--cache)))))))

;;;; The mode

(defun lispm-kernel-desktop--start ()
  "Start the kernel and register the session readers."
  (unless lispm-kernel-desktop--runtime
    (setq lispm-kernel-desktop--early-exits 0
          lispm-kernel-desktop--restart-at nil)
    (lispm-kernel-desktop--start-runtime (lispm-kernel-desktop--program)))
  (dolist (spec lispm-kernel-desktop--agents)
    (let ((agent (car spec)))
      (lispm-agents-add-session-reader
       agent (lambda () (lispm-kernel-desktop--read agent)))))
  (when (boundp 'lispm-agents-read-sessions-function)
    (add-function :around lispm-agents-read-sessions-function #'lispm-kernel-desktop--current))
  (add-hook 'lispm-agents-session-lookup-functions #'lispm-kernel-desktop--lookup)
  (add-hook 'lispm-agents-reread-sessions-hook #'lispm-kernel-desktop-invalidate))

(defun lispm-kernel-desktop--unavailable ()
  "Signal that no program can be had, saying why."
  (setq lispm-kernel-desktop-last-error (or lispm-kernel-program-problem 'program-unavailable))
  (user-error "No lispm-kernel program, so the agents read sessions themselves: %s"
              (or lispm-kernel-program-problem "none is there")))

(defun lispm-kernel-desktop--obtained (there)
  "Finish turning the mode on now that the program is THERE, or turn it off.
This is on `lispm-kernel-program-obtained-functions' while the mode waits
for the program."
  (remove-hook 'lispm-kernel-program-obtained-functions #'lispm-kernel-desktop--obtained)
  (when (and lispm-kernel-sessions-mode (not lispm-kernel-desktop--runtime))
    (condition-case error
        (if there (lispm-kernel-desktop--start) (lispm-kernel-desktop--unavailable))
      (error
       (lispm-kernel-sessions-mode -1)
       (message "%s" (error-message-string error))))))

(defun lispm-kernel-desktop--enable ()
  "Start the kernel and register session readers now or once obtained.
Signals an error when neither session readers nor a kernel program can be had."
  (require 'lispm-agents)
  (require 'lispm-agents-codex)
  (require 'lispm-agents-claude)
  (unless (fboundp 'lispm-agents-add-session-reader)
    (user-error "This lispm-agent has no session readers; update it"))
  (if (or lispm-kernel-desktop--runtime lispm-kernel-desktop-program)
      (lispm-kernel-desktop--start)
    (pcase (lispm-kernel-program-obtain)
      ('ready (lispm-kernel-desktop--start))
      ;; Until it is there, the agents' own readers answer.
      ('pending (add-hook 'lispm-kernel-program-obtained-functions #'lispm-kernel-desktop--obtained))
      (_ (lispm-kernel-desktop--unavailable)))))

(defun lispm-kernel-desktop--disable ()
  "Give the sessions back to the agents' own readers and stop the kernel."
  (remove-hook 'lispm-kernel-program-obtained-functions #'lispm-kernel-desktop--obtained)
  (when (fboundp 'lispm-agents-remove-session-reader)
    (dolist (spec lispm-kernel-desktop--agents)
      (lispm-agents-remove-session-reader (car spec))))
  (when (boundp 'lispm-agents-read-sessions-function)
    (remove-function lispm-agents-read-sessions-function #'lispm-kernel-desktop--current))
  (remove-hook 'lispm-agents-session-lookup-functions #'lispm-kernel-desktop--lookup)
  (remove-hook 'lispm-agents-reread-sessions-hook #'lispm-kernel-desktop-invalidate)
  (when lispm-kernel-desktop--runtime
    (lispm-kernel-stop lispm-kernel-desktop--runtime))
  (maphash (lambda (_ state)
             (when-let* ((runtime (plist-get state :runtime)))
               (lispm-kernel-stop runtime)))
           lispm-kernel-desktop--hosts)
  (clrhash lispm-kernel-desktop--hosts)
  (setq lispm-kernel-desktop--runtime nil
        lispm-kernel-desktop--restart-at nil)
  (maphash (lambda (_ entry) (lispm-kernel-desktop--forget-timer entry))
           lispm-kernel-desktop--cache)
  (clrhash lispm-kernel-desktop--cache)
  (when (fboundp 'lispm-agents-sessions-arrived)
    (lispm-agents-sessions-arrived)))

(define-minor-mode lispm-kernel-sessions-mode
  "Read Codex and Claude sessions for the editor's agents in the background.
Needs lispm-agent's session readers, and the kernel program: the one
`lispm-kernel-desktop-program' names, else the one downloaded for these
sources and checked against the SHA-256 pinned with the Lisp, or built
with SBCL when `lispm-kernel-program-source' says so, in the
background, see `lispm-kernel-program-obtain'.  Until that is there the
agents' own readers answer; without session readers or a program to be
had, the mode turns off, saying why, and they stay in use."
  :global t :group 'lispm-kernel
  (if (not lispm-kernel-sessions-mode)
      (lispm-kernel-desktop--disable)
    (condition-case error
        (lispm-kernel-desktop--enable)
      (error
       (setq lispm-kernel-sessions-mode nil)
       (lispm-kernel-desktop--disable)
       (signal (car error) (cdr error))))))

(define-obsolete-function-alias 'lispm-kernel-desktop-mode #'lispm-kernel-sessions-mode "0.4.0")

(defun lispm-kernel-desktop-unload-function ()
  "Give the sessions back to the agents before `unload-feature' runs."
  (when lispm-kernel-sessions-mode (lispm-kernel-sessions-mode -1))
  nil)

(provide 'lispm-kernel-desktop)
;;; lispm-kernel-desktop.el ends here
