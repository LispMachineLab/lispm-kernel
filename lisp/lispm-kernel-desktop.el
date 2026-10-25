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
;; - the list of every session a terminal learns its session from,
;;   however old, `lispm-agents-sessions-arrived' telling when a newer
;;   one comes, and the session picker's, at most that old, waiting
;;   `lispm-kernel-desktop-wait-seconds' at most for one, else read the
;;   agents' own way (`lispm-agents-read-sessions-function').
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

(defcustom lispm-kernel-desktop-wait-seconds 1
  "Seconds a list of every session, as the session picker's, waits for the
kernel to read them anew, before the agents' own reader reads them."
  :type 'number :group 'lispm-kernel)

(defcustom lispm-kernel-desktop-scan-timeout 60
  "Seconds the kernel may take reading before the agents' own reader is used."
  :type 'number :group 'lispm-kernel)

(defcustom lispm-kernel-desktop-restart-seconds 10
  "A kernel that ran shorter than this before it exited is started again
only after a while: this many seconds after it exited, twice as many if
the next does so too, and so on up to `lispm-kernel-desktop-restart-limit'.
One that ran longer is started again when a reader next asks."
  :type 'number :group 'lispm-kernel)

(defcustom lispm-kernel-desktop-restart-limit 600
  "The most seconds a kernel that keeps exiting soon after it started
waits to be started again, see `lispm-kernel-desktop-restart-seconds'."
  :type 'number :group 'lispm-kernel)

(defconst lispm-kernel-desktop--agents
  '((codex :owner 1 :root lispm-agents-codex-sessions-directory
           :index lispm-agents-codex-index-file
           :read lispm-agents-codex-sessions)
    (claude :owner 2 :root lispm-agents-claude-projects-directory
            :read lispm-agents-claude-sessions))
  "The agents read by the kernel: their owner, the variables naming their
root and index, and their own reader.")

(defvar lispm-kernel-desktop--runtime nil)

(defvar lispm-kernel-desktop--cache (make-hash-table :test #'eq)
  "Per agent, a plist (:root :generation :sessions :known :time :turns
:request :started :retry-timer).  :known is non-nil once sessions were
read, :time is when, nil when they must be read anew; :turns is non-nil
when the kernel read them, saying whether their latest turn ended.")

(defvar lispm-kernel-desktop-last-error nil
  "Why the kernel could not read sessions last, or nil.")

(defvar lispm-kernel-desktop--early-exits 0
  "How many kernels in a row exited sooner than
`lispm-kernel-desktop-restart-seconds' after they started.")

(defvar lispm-kernel-desktop--restart-at nil
  "When the kernel that exited is started again, a `float-time', or nil
while it runs or its exit was not seen yet.")

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
  "Return the program to run: `lispm-kernel-desktop-program', else the one
lispm-kernel-program.el has."
  (or lispm-kernel-desktop-program (lispm-kernel-program-file)))

(defun lispm-kernel-desktop--start-runtime (program)
  "Run PROGRAM as the agents' kernel."
  (setq lispm-kernel-desktop--runtime (lispm-kernel-start program)))

(defun lispm-kernel-desktop--restart-delay ()
  "Return how many seconds after its exit a kernel that exited soon after
it started waits to be started again, as many such exits in a row as
`lispm-kernel-desktop--early-exits' counts."
  (min lispm-kernel-desktop-restart-limit
       (* lispm-kernel-desktop-restart-seconds
          (expt 2 (min 30 (max 0 (1- lispm-kernel-desktop--early-exits)))))))

(defun lispm-kernel-desktop--start-again ()
  "Stop the agents' kernel, if it runs, and start it again, everything
read anew; return it, or nil when it could not be started, saying why in
`lispm-kernel-desktop-last-error' and trying again after a while."
  (when lispm-kernel-desktop--runtime
    (lispm-kernel-stop lispm-kernel-desktop--runtime))
  (condition-case error
      (progn
        ;; What the old one read is gone with it: read everything anew.
        (maphash (lambda (_ entry)
                   (lispm-kernel-desktop--forget-timer entry))
                 lispm-kernel-desktop--cache)
        (clrhash lispm-kernel-desktop--cache)
        (lispm-kernel-desktop--start-runtime
         (or (lispm-kernel-desktop--program) (error "No lispm-kernel program is there")))
        (setq lispm-kernel-desktop--restart-at nil)
        lispm-kernel-desktop--runtime)
    (error (setq lispm-kernel-desktop-last-error error
                 lispm-kernel-desktop--restart-at (+ (float-time) lispm-kernel-desktop-restart-seconds))
           nil)))

(defun lispm-kernel-desktop--runtime ()
  "Return the agents' kernel when it runs, starting it again once it
exited; else nil.  A kernel that ran shorter than
`lispm-kernel-desktop-restart-seconds' is started again only after a
while, see `lispm-kernel-desktop--restart-delay'."
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
    (user-error "lispm-kernel-sessions-mode is off"))
  (setq lispm-kernel-desktop--early-exits 0)
  (cond (lispm-kernel-desktop--runtime
         (unless (lispm-kernel-desktop--start-again)
           (user-error "lispm-kernel could not be started: %s"
                       (lispm-kernel-desktop--why lispm-kernel-desktop-last-error))))
        ((lispm-kernel-program-busy-p)
         (message "lispm-kernel starts once its program is there"))
        (t (lispm-kernel-desktop--enable))))

(defun lispm-kernel-desktop--why (error)
  "Return ERROR, a sentence, an error or a summary, as a sentence."
  (cond ((stringp error) error)
        ((and (consp error) (symbolp (car error)) (get (car error) 'error-conditions))
         (error-message-string error))
        (t (format "%s" error))))

(defun lispm-kernel-desktop-status ()
  "Return how the agents' kernel stands, for a control panel to say:
  (off)                       the mode is off
  (getting FRACTION)          its program is downloaded, FRACTION of it
                              there, or nil while that is not known, or
                              built
  (running PROCESS SINCE)     it runs as PROCESS since SINCE, a `float-time'
  (exited WHY AT)             it exited, WHY says why, and starts again
                              at AT, a `float-time', when a reader asks"
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

(defun lispm-kernel-desktop-runtime ()
  "Return the agents' kernel while `lispm-kernel-sessions-mode' runs it,
else nil.  One that exited is started again, as the session readers have
it."
  (and lispm-kernel-sessions-mode (lispm-kernel-desktop--runtime)))

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
  "Keep AGENT's SESSIONS of GENERATION as SUMMARY says; tell the agents."
  (when lispm-kernel-sessions-mode
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
          (let ((known (plist-get entry :known))
                (old (plist-get entry :sessions))
                (sessions (if (plist-get summary :error) (plist-get entry :sessions) sessions)))
            (lispm-kernel-desktop--update
             agent generation :request nil :time (float-time) :known t
             :turns (plist-get summary :turn-ended) :sessions sessions)
            ;; Read again as they were, they need not be drawn again.
            (unless (and known (equal sessions old))
              (lispm-agents-sessions-arrived)))))))))

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
  (when (and lispm-kernel-sessions-mode
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
missing root, or no kernel running, is read the agents' own way."
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

(defun lispm-kernel-desktop--fresh (agent &optional since)
  "Return AGENT's cache entry when it holds sessions the kernel read since
SINCE, a `float-time', by default `lispm-kernel-desktop-cache-seconds'
ago, saying whether their latest turn ended, else nil.  A kernel older
than this Lisp says nothing of turns: what it read may want sessions
lispm-agent reads."
  (let ((entry (gethash agent lispm-kernel-desktop--cache)))
    (and (plist-get entry :known)
         (plist-get entry :turns)
         (plist-get entry :time)
         (>= (plist-get entry :time) (or since (- (float-time) lispm-kernel-desktop-cache-seconds)))
         entry)))

(defun lispm-kernel-desktop--read-lately (agent)
  "Return AGENT's cache entry when it holds sessions the kernel read, of
any age, see `lispm-kernel-desktop--fresh', `pending' before the first
such, or nil.  A stale reading starts another, which says so when it
comes, see `lispm-agents-sessions-arrived'."
  (let ((root (lispm-kernel-desktop--value agent :root))
        (runtime (lispm-kernel-desktop-runtime)))
    (when (and runtime (stringp root) (not (file-remote-p root)) (file-directory-p root))
      (let ((entry (lispm-kernel-desktop--entry runtime agent root)))
        (when (lispm-kernel-desktop--stale-p entry)
          (lispm-kernel-desktop--scan runtime agent))
        (or (lispm-kernel-desktop--fresh agent 0)
            (and (not (plist-get (gethash agent lispm-kernel-desktop--cache) :known))
                 'pending))))))

(defun lispm-kernel-desktop--read-now (agent)
  "Return AGENT's cache entry once it holds a fresh reading, see
`lispm-kernel-desktop--fresh', else waiting for the kernel to read them
anew, at most `lispm-kernel-desktop-wait-seconds'; nil when none comes.
While it waits, only the kernel's messages are taken in, no timer
running."
  (let ((root (lispm-kernel-desktop--value agent :root))
        (runtime (lispm-kernel-desktop-runtime)))
    (when (and runtime (stringp root) (not (file-remote-p root)) (file-directory-p root))
      (let ((entry (lispm-kernel-desktop--entry runtime agent root)))
        (or (lispm-kernel-desktop--fresh agent)
            ;; Not while the kernel's messages are taken in: none more would be.
            (unless (lispm-kernel-runtime-dispatching runtime)
              (when (lispm-kernel-desktop--stale-p entry)
                (lispm-kernel-desktop--scan runtime agent))
              (let* ((since (float-time))
                     (deadline (+ since lispm-kernel-desktop-wait-seconds))
                     (process (lispm-kernel-runtime-process runtime))
                     request)
                (while (and (not (lispm-kernel-desktop--fresh agent since))
                            (integerp (setq request (plist-get (gethash agent lispm-kernel-desktop--cache)
                                                               :request)))
                            (gethash request (lispm-kernel-runtime-requests runtime))
                            (lispm-kernel-live-p runtime)
                            (< (float-time) deadline))
                  (accept-process-output process 0.01 nil 1)
                  (lispm-kernel-dispatch runtime))
                (lispm-kernel-desktop--fresh agent since))))))))

(defun lispm-kernel-desktop--current (read agent sessions &optional recent)
  "Return AGENT's sessions as the kernel read them lately, else as READ,
the function this wraps, reads them with SESSIONS, AGENT's :sessions.
When RECENT, what it read a while ago will do, or none while it reads
them first, see `lispm-kernel-desktop--read-lately'; else what it read
last if fresh, see `lispm-kernel-desktop--read-now'.  This is around
`lispm-agents-read-sessions-function' while the mode is on."
  (pcase (and (assq agent lispm-kernel-desktop--agents)
              (if recent
                  (lispm-kernel-desktop--read-lately agent)
                (lispm-kernel-desktop--read-now agent)))
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
  "Start the kernel and register the session readers, now, or once the
program is built or downloaded; signal when impossible."
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
