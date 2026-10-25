;;; lispm-kernel-desktop-test.el --- The kernel reading the agents' sessions -*- lexical-binding: t; -*-

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

;; Against lispm-agent's session readers, whose own readers are the
;; reference: what the kernel reads must be what they read.  No LispM
;; Desktop is loaded: the kernel's messages are taken in by timers.  Load
;; after lispm-kernel-test.el, which names the program.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lispm-kernel-desktop)
(require 'lispm-agents-codex)
(require 'lispm-agents-claude)
;; Loaded before any test fakes their functions: loading them later would
;; replace the fakes, and undoing a fake would then unbind the real ones.
(require 'lispm-agents)
(defvar lispm-kernel-test-program)

(defvar lispm-kernel-desktop-test--readers nil
  "Readers the faked desktop registry holds, an alist (AGENT . READER).")

(defvar lispm-kernel-desktop-test--arrived 0
  "How often `lispm-agents-sessions-arrived' was called.")

(defmacro lispm-kernel-desktop-test--with-desktop (&rest body)
  "Run BODY with the desktop's reader registry recorded and the program
under test, then turn the mode off."
  (declare (indent 0))
  `(let ((lispm-kernel-desktop-test--readers nil)
         (lispm-kernel-desktop-test--arrived 0)
         (lispm-kernel-desktop-program lispm-kernel-test-program)
         (lispm-kernel-desktop-last-error nil))
     (cl-letf (((symbol-function 'lispm-agents-add-session-reader)
                (lambda (agent reader)
                  (setf (alist-get agent lispm-kernel-desktop-test--readers) reader)))
               ((symbol-function 'lispm-agents-remove-session-reader)
                (lambda (agent)
                  (setf (alist-get agent lispm-kernel-desktop-test--readers nil t) nil)))
               ((symbol-function 'lispm-agents-sessions-arrived)
                (lambda () (cl-incf lispm-kernel-desktop-test--arrived))))
       (unwind-protect (progn ,@body)
         (lispm-kernel-sessions-mode -1)))))

(defun lispm-kernel-desktop-test--read (agent)
  "Call AGENT's registered reader."
  (funcall (alist-get agent lispm-kernel-desktop-test--readers)))

(defun lispm-kernel-desktop-test--read-until-known (agent)
  "Call AGENT's reader until it stops answering `pending'; return its sessions."
  (let ((deadline (+ (float-time) 10)) (sessions 'pending))
    (while (and (eq sessions 'pending) (< (float-time) deadline))
      (accept-process-output nil 0.005)
      (when (lispm-kernel-live-p lispm-kernel-desktop--runtime)
        (lispm-kernel-dispatch lispm-kernel-desktop--runtime))
      (setq sessions (lispm-kernel-desktop-test--read agent)))
    sessions))

(defun lispm-kernel-desktop-test--write (file &rest objects)
  "Write OBJECTS to FILE as JSON Lines, and FILE's directory."
  (make-directory (file-name-directory file) t)
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file file
      (dolist (object objects)
        (insert (if (stringp object) object (decode-coding-string (json-serialize object) 'utf-8))
                "\n"))))
  file)

(defun lispm-kernel-desktop-test--codex-tree (directory)
  "Write Codex transcripts and an index in DIRECTORY."
  (let ((day (expand-file-name "2026/10/21/" directory)))
    (lispm-kernel-desktop-test--write
     (expand-file-name "rollout-1.jsonl" day)
     '(:type "session_meta" :payload (:id "one" :cwd "/w/one" :timestamp "2026-10-21T01:00:00.123Z"))
     '(:type "response_item" :payload (:type "message" :role "user"
                                       :content [(:type "input_text" :text "<environment_context>")]))
     '(:type "event_msg" :payload (:type "user_message" :message "# AGENTS.md here"))
     '(:type "event_msg" :payload (:type "user_message" :message "  Fix the build\nplease")))
    (lispm-kernel-desktop-test--write
     (expand-file-name "rollout-1-fork.jsonl" day)
     '(:type "session_meta" :payload (:id "one" :cwd "/w/one" :timestamp "2026-10-21T02:00:00Z"))
     '(:type "response_item" :payload (:type "message" :role "user"
                                       :content [(:type "input_text" :text "forked ")
                                                 (:type "input_text" :text "prompt")])))
    (set-file-times (expand-file-name "rollout-1.jsonl" day) (seconds-to-time 1700000000))
    (lispm-kernel-desktop-test--write
     (expand-file-name "ROLLOUT-2.JSONL" day)
     '(:type "session_meta" :payload (:id "two" :cwd "/w/two" :timestamp "not a time")))
    (lispm-kernel-desktop-test--write
     (expand-file-name "rollout-3.jsonl" day)
     "not json"
     '(:type "session_meta" :payload (:id "three" :cwd "/w/three"))
     (concat (decode-coding-string
              (json-serialize '(:type "event_msg" :payload (:type "user_message" :message "big")))
              'utf-8)
             (make-string 70000 ?\s)))
    (lispm-kernel-desktop-test--write
     (expand-file-name "rollout-4.jsonl" day)
     '(:type "session_meta" :payload (:id "four" :cwd "/w/four"))
     (list :type "event_msg" :payload (list :type "user_message"
                                            :message (concat "Unicode " (string #xe9 #x3bb #x1f600)))))
    (lispm-kernel-desktop-test--write
     (expand-file-name "session_index.jsonl" (file-name-directory (directory-file-name directory)))
     '(:id "two" :thread_name "Named two")
     '(:id "four" :thread_name "Old name")
     '(:id "four" :thread_name "New name"))))

(defun lispm-kernel-desktop-test--claude-tree (directory)
  "Write Claude Code transcripts in DIRECTORY."
  (lispm-kernel-desktop-test--write
   (expand-file-name "project/a.jsonl" directory)
   '(:type "user" :cwd "/c/a" :isMeta t :message (:content "ignore me"))
   '(:type "user" :cwd "/c/a" :message (:content [(:text "hello ") (:text "there")])))
  (apply #'lispm-kernel-desktop-test--write
         (expand-file-name "project/b.jsonl" directory)
         '(:type "user" :cwd "/c/b" :message (:content "early"))
         (append (make-list 900 '(:type "assistant" :x "......................................................................................"))
                 '((:type "summary" :summary "Late summary"))))
  (lispm-kernel-desktop-test--write
   (expand-file-name "project/c.jsonl" directory)
   '(:type "custom-title" :customTitle "In the transcript")
   '(:type "user" :cwd "/c/c" :message (:content "third")))
  (lispm-kernel-desktop-test--write
   (expand-file-name "project/c/custom-title.json" directory)
   '(:customTitle "From its file"))
  (lispm-kernel-desktop-test--write
   (expand-file-name "project/d.jsonl" directory)
   '(:type "user" :message (:content "no cwd")))
  (lispm-kernel-desktop-test--write
   (expand-file-name ".other/e.jsonl" directory)
   '(:type "user" :cwd "/c/e" :message (:content "<command-name>"))
   '(:type "summary" :summary "Only a summary")))

(defun lispm-kernel-desktop-test--sorted (sessions)
  "Return SESSIONS sorted by file, as the desktop compares them."
  (sort (copy-sequence sessions) (lambda (a b) (string< (plist-get a :file) (plist-get b :file)))))

(defmacro lispm-kernel-desktop-test--with-trees (&rest body)
  "Run BODY with the desktop's Codex and Claude roots in a new directory."
  (declare (indent 0))
  `(let* ((directory (make-temp-file "lispm-kernel-desktop" t))
          (lispm-agents-codex-sessions-directory (expand-file-name "codex/sessions/" directory))
          (lispm-agents-codex-index-file (expand-file-name "codex/session_index.jsonl" directory))
          (lispm-agents-claude-projects-directory (expand-file-name "claude/projects/" directory)))
     (unwind-protect
         (progn
           (lispm-kernel-desktop-test--codex-tree lispm-agents-codex-sessions-directory)
           (lispm-kernel-desktop-test--claude-tree lispm-agents-claude-projects-directory)
           ;; Sessions of one time, ordered by where their files are.
           (dolist (file (list (expand-file-name "2026/10/21/ROLLOUT-2.JSONL" lispm-agents-codex-sessions-directory)
                               (expand-file-name "2026/10/21/rollout-4.jsonl" lispm-agents-codex-sessions-directory)
                               (expand-file-name "project/a.jsonl" lispm-agents-claude-projects-directory)
                               (expand-file-name "project/c.jsonl" lispm-agents-claude-projects-directory)
                               (expand-file-name ".other/e.jsonl" lispm-agents-claude-projects-directory)))
             (set-file-times file (seconds-to-time 1750000000)))
           ,@body)
       (delete-directory directory t))))

(defmacro lispm-kernel-test--with-trees-and-desktop (program &rest body)
  "Run BODY with the desktop's trees and registry, the kernel PROGRAM."
  (declare (indent 1))
  `(lispm-kernel-desktop-test--with-trees
     (lispm-kernel-desktop-test--with-desktop
       (let ((lispm-kernel-desktop-program ,program))
         ,@body))))

(ert-deftest lispm-kernel-desktop-reads-as-the-desktop-does ()
  (lispm-kernel-desktop-test--with-trees
    (lispm-kernel-desktop-test--with-desktop
      (lispm-kernel-sessions-mode 1)
      (should (assq 'codex lispm-kernel-desktop-test--readers))
      (should (assq 'claude lispm-kernel-desktop-test--readers))
      (should (memq #'lispm-kernel-desktop-invalidate lispm-agents-reread-sessions-hook))
      ;; Taken in by timers: the mode sets no scheduler of its own.
      (should-not lispm-kernel-scheduler)
      (dolist (agent '(codex claude))
        (should (eq (lispm-kernel-desktop-test--read agent) 'pending))
        (let ((sessions (lispm-kernel-desktop-test--read-until-known agent))
              (reference (funcall (if (eq agent 'codex)
                                      #'lispm-agents-codex-sessions
                                    #'lispm-agents-claude-sessions))))
          ;; As the sidebar draws them, those of one time in one order too.
          (should (equal (lispm-agents--sort-sessions sessions)
                         (lispm-agents--sort-sessions reference)))
          (should (= (length sessions) (if (eq agent 'codex) 3 4)))))
      (should (> lispm-kernel-desktop-test--arrived 0))
      (should-not lispm-kernel-desktop-last-error))))

(ert-deftest lispm-kernel-desktop-reads-again-when-stale ()
  (lispm-kernel-desktop-test--with-trees
    (lispm-kernel-desktop-test--with-desktop
      (lispm-kernel-sessions-mode 1)
      (let ((first (lispm-kernel-desktop-test--read-until-known 'claude)))
        ;; Fresh: no reading starts.
        (lispm-kernel-desktop-test--read 'claude)
        (should-not (plist-get (gethash 'claude lispm-kernel-desktop--cache) :request))
        (lispm-kernel-desktop-test--write
         (expand-file-name "project/f.jsonl" lispm-agents-claude-projects-directory)
         '(:type "user" :cwd "/c/f" :message (:content "new one")))
        ;; Stale: the old sessions answer while the new are read.
        (let ((lispm-kernel-desktop-cache-seconds 0))
          (should (equal (lispm-kernel-desktop-test--read 'claude) first))
          (should (integerp (plist-get (gethash 'claude lispm-kernel-desktop--cache) :request)))
          (should (lispm-kernel-test--wait
                   lispm-kernel-desktop--runtime
                   (lambda () (null (plist-get (gethash 'claude lispm-kernel-desktop--cache) :request))))))
        (should (= (length (lispm-kernel-desktop-test--read 'claude)) (1+ (length first))))))))

(ert-deftest lispm-kernel-desktop-reread-supersedes-and-keeps-old-sessions ()
  (lispm-kernel-desktop-test--with-desktop
    (lispm-kernel-sessions-mode 1)
    (puthash 'codex '(:root "/r" :sessions ((:id "old")) :known t :generation 0 :time 1 :request 42)
             lispm-kernel-desktop--cache)
    (run-hooks 'lispm-agents-reread-sessions-hook)
    (let ((entry (gethash 'codex lispm-kernel-desktop--cache)))
      (should (= (plist-get entry :generation) 1))
      (should-not (plist-get entry :request))
      (should-not (plist-get entry :time))
      (should (plist-get entry :known))
      (should (equal (plist-get entry :sessions) '((:id "old")))))))

(ert-deftest lispm-kernel-desktop-off-gives-everything-back ()
  (lispm-kernel-desktop-test--with-desktop
    (lispm-kernel-sessions-mode 1)
    (let ((runtime lispm-kernel-desktop--runtime))
      (lispm-kernel-sessions-mode 1)
      (should (eq runtime lispm-kernel-desktop--runtime))
      (lispm-kernel-sessions-mode -1)
      (should-not lispm-kernel-desktop-test--readers)
      (should-not (memq #'lispm-kernel-desktop-invalidate lispm-agents-reread-sessions-hook))
      (should-not lispm-kernel-desktop--runtime)
      (should-not (process-live-p (lispm-kernel-runtime-process runtime))))))

(ert-deftest lispm-kernel-desktop-remote-root-uses-the-desktop-reader ()
  (let ((lispm-agents-codex-sessions-directory "/ssh:host:/sessions/") called)
    (lispm-kernel-desktop-test--with-desktop
      (lispm-kernel-sessions-mode 1)
      (cl-letf (((symbol-function 'lispm-agents-codex-sessions)
                 (lambda () (setq called t) '((:id "remote")))))
        (should (equal (lispm-kernel-desktop-test--read 'codex) '((:id "remote"))))
        (should called)))))

(ert-deftest lispm-kernel-desktop-restarts-a-kernel-that-dies-at-once-after-a-while ()
  "A kernel that exits soon after it started is started again only after a
while, twice as long each time in a row, up to the limit; restarting it
by hand tries it at once."
  (let ((program (make-temp-file "lispm-kernel-dies" nil nil "#!/bin/sh\nexit 3\n"))
        (starts 0))
    (set-file-modes program #o755)
    (unwind-protect
        (lispm-kernel-test--with-trees-and-desktop program
          (let ((start (symbol-function 'lispm-kernel-start))
                (lispm-kernel-desktop-restart-seconds 0.5)
                (lispm-kernel-desktop-restart-limit 1.5)
                (died (lambda ()
                        (lispm-kernel-test--wait lispm-kernel-desktop--runtime
                                                 (lambda () (lispm-kernel-runtime-exited lispm-kernel-desktop--runtime)))))
                (read (lambda ()
                        (should (equal (lispm-kernel-desktop-test--sorted (lispm-kernel-desktop-test--read 'claude))
                                       (lispm-kernel-desktop-test--sorted (lispm-agents-claude-sessions)))))))
            (cl-letf (((symbol-function 'lispm-kernel-start)
                       (lambda (file) (cl-incf starts) (funcall start file))))
              (lispm-kernel-sessions-mode 1)
              (funcall died)
              ;; The desktop's reader answers meanwhile, and it is not
              ;; started again at once.
              (funcall read)
              (should (= starts 1))
              (should (eq (car (lispm-kernel-desktop-status)) 'exited))
              (should (string-match-p "exited" (cadr (lispm-kernel-desktop-status))))
              (should (= lispm-kernel-desktop--early-exits 1))
              ;; After the restart seconds it is.
              (setq lispm-kernel-desktop--restart-at (- (float-time) 0.01))
              (lispm-kernel-desktop-test--read 'claude)
              (should (= starts 2))
              (funcall died)
              (funcall read)
              ;; The second time in a row it waits twice as long, then no
              ;; longer than the limit.
              (should (= lispm-kernel-desktop--early-exits 2))
              (should (= (lispm-kernel-desktop--restart-delay) 1.0))
              (setq lispm-kernel-desktop--early-exits 5)
              (should (= (lispm-kernel-desktop--restart-delay) 1.5))
              (setq lispm-kernel-desktop--early-exits 2)
              (should (= starts 2))
              ;; Restarted by hand, it is tried at once.
              (lispm-kernel-desktop-restart)
              (should (= starts 3))
              (should (= lispm-kernel-desktop--early-exits 0))
              (funcall died)
              (funcall read)
              (should (= starts 3))
              (should (= lispm-kernel-desktop--early-exits 1)))))
      (delete-file program))))

(ert-deftest lispm-kernel-desktop-status-and-restart ()
  "The status says the mode is off, the kernel runs, or it exited; the
restart command starts a running kernel anew."
  (lispm-kernel-desktop-test--with-trees
    (lispm-kernel-desktop-test--with-desktop
      (should (equal (lispm-kernel-desktop-status) '(off)))
      (should-error (lispm-kernel-desktop-restart) :type 'user-error)
      (lispm-kernel-sessions-mode 1)
      (let ((runtime lispm-kernel-desktop--runtime))
        (pcase (lispm-kernel-desktop-status)
          (`(running ,process ,since)
           (should (eq process (lispm-kernel-runtime-process runtime)))
           (should (numberp since)))
          (status (ert-fail (list "not running" status))))
        (lispm-kernel-desktop-restart)
        (should-not (eq runtime lispm-kernel-desktop--runtime))
        (should-not (lispm-kernel-live-p runtime))
        (should (lispm-kernel-live-p lispm-kernel-desktop--runtime))
        (should (eq (car (lispm-kernel-desktop-status)) 'running))))))

(ert-deftest lispm-kernel-desktop-kernel-exits ()
  (lispm-kernel-desktop-test--with-trees
    (lispm-kernel-desktop-test--with-desktop
      (lispm-kernel-sessions-mode 1)
      (let ((runtime lispm-kernel-desktop--runtime)
            (reference (lispm-agents-claude-sessions)))
        (lispm-kernel-test--wait runtime (lambda () (lispm-kernel-runtime-hello runtime)))
        (signal-process (lispm-kernel-runtime-process runtime) 'KILL)
        (lispm-kernel-test--wait runtime (lambda () (not (lispm-kernel-live-p runtime))))
        (should (string-match-p "exited" (lispm-kernel-why-not-running runtime)))
        (lispm-kernel-test--wait runtime (lambda () (lispm-kernel-runtime-exited runtime)))
        ;; Soon after it started: not again; the desktop's reader answers.
        (should (equal (lispm-kernel-desktop-test--read 'claude) reference))
        (should (eq runtime lispm-kernel-desktop--runtime))
        (should (string-match-p "exited" (format "%s" lispm-kernel-desktop-last-error)))
        ;; Later: started again.
        (setq lispm-kernel-desktop--restart-at (- (float-time) 0.01))
        (should (eq (lispm-kernel-desktop-test--read 'claude) 'pending))
        (should-not (eq runtime lispm-kernel-desktop--runtime))
        (should (lispm-kernel-live-p lispm-kernel-desktop--runtime))
        (should (equal (lispm-kernel-desktop-test--sorted (lispm-kernel-desktop-test--read-until-known 'claude))
                       (lispm-kernel-desktop-test--sorted reference)))))))

(ert-deftest lispm-kernel-desktop-falls-back-when-the-kernel-cannot-read ()
  (lispm-kernel-desktop-test--with-trees
    (lispm-kernel-desktop-test--with-desktop
      (lispm-kernel-sessions-mode 1)
      (cl-letf (((symbol-function 'lispm-kernel-scan-sessions)
                 (lambda (_runtime _agent _root callback &rest options)
                   (run-at-time 0 nil (lambda ()
                                        (funcall callback (funcall (plist-get options :fallback))
                                                 '(:source elisp :native-error (failed "no")))))
                   7)))
        (should (equal (lispm-kernel-desktop-test--sorted (lispm-kernel-desktop-test--read-until-known 'claude))
                       (lispm-kernel-desktop-test--sorted (lispm-agents-claude-sessions))))
        (should (equal (plist-get lispm-kernel-desktop-last-error :native-error) '(failed "no")))))))

(ert-deftest lispm-kernel-desktop-retries-when-the-kernel-is-full ()
  (lispm-kernel-desktop-test--with-trees
    (lispm-kernel-desktop-test--with-desktop
      (lispm-kernel-sessions-mode 1)
      (let ((scan (symbol-function 'lispm-kernel-scan-sessions))
            (attempts 0))
        (cl-letf (((symbol-function 'lispm-kernel-scan-sessions)
                   (lambda (runtime agent root callback &rest options)
                     (cl-incf attempts)
                     (if (= attempts 1)
                         (progn (run-at-time 0 nil callback nil '(:rejected capacity)) 7)
                       (apply scan runtime agent root callback options)))))
          (should (eq (lispm-kernel-desktop-test--read 'claude) 'pending))
          (should (= (length (lispm-kernel-desktop-test--read-until-known 'claude)) 4))
          (should (= attempts 2)))))))

(ert-deftest lispm-kernel-desktop-waits-for-the-program ()
  "With no program named or there, the mode is on while one is built or
downloaded, the desktop's own readers answering; the kernel's are
registered once it is there, and the mode turns off when none can be had."
  (lispm-kernel-desktop-test--with-desktop
    (let ((lispm-kernel-desktop-program nil)
          (lispm-kernel-program-problem nil)
          (lispm-kernel-program-obtained-functions nil)
          (inhibit-message t)
          (messages nil)
          (asked 0))
      (cl-letf (((symbol-function 'lispm-kernel-program-obtain) (lambda () (cl-incf asked) 'pending))
                ((symbol-function 'lispm-kernel-program-file) (lambda () lispm-kernel-test-program)))
        (lispm-kernel-sessions-mode 1)
        (should lispm-kernel-sessions-mode)
        (should (= asked 1))
        (should-not lispm-kernel-desktop--runtime)
        (should-not lispm-kernel-desktop-test--readers)
        (run-hook-with-args 'lispm-kernel-program-obtained-functions t)
        (should (lispm-kernel-live-p lispm-kernel-desktop--runtime))
        (should (assq 'codex lispm-kernel-desktop-test--readers))
        (should-not lispm-kernel-program-obtained-functions)
        (lispm-kernel-sessions-mode -1)
        ;; None could be got, and the user is told why.
        (lispm-kernel-sessions-mode 1)
        (setq lispm-kernel-program-problem "its SHA-256 differs, so it was refused")
        (cl-letf (((symbol-function 'message)
                   (lambda (format &rest args) (push (apply #'format format args) messages))))
          (run-hook-with-args 'lispm-kernel-program-obtained-functions nil))
        (should-not lispm-kernel-sessions-mode)
        (should-not lispm-kernel-desktop-test--readers)
        (should (equal lispm-kernel-desktop-last-error lispm-kernel-program-problem))
        (should (seq-some (lambda (text) (string-search "so it was refused" text)) messages))
        ;; Turned off while waiting, it stays off once the program is there.
        (lispm-kernel-sessions-mode 1)
        (lispm-kernel-sessions-mode -1)
        (should-not lispm-kernel-program-obtained-functions)
        (should-not lispm-kernel-desktop--runtime))
      ;; Nothing to be had at all.
      (cl-letf (((symbol-function 'lispm-kernel-program-obtain) #'ignore))
        (should-error (lispm-kernel-sessions-mode 1) :type 'user-error))
      (should-not lispm-kernel-sessions-mode)
      (should-not lispm-kernel-desktop-test--readers)
      (should-not lispm-kernel-desktop--runtime))))

(ert-deftest lispm-kernel-desktop-mode-is-the-sessions-mode ()
  "The mode's old name, of when LispM Desktop held the agents, still turns
it on and off, and says whether it is on."
  (lispm-kernel-desktop-test--with-desktop
    (with-suppressed-warnings ((obsolete lispm-kernel-desktop-mode))
      (lispm-kernel-desktop-mode 1)
      (should lispm-kernel-sessions-mode)
      (should lispm-kernel-desktop-mode)
      (lispm-kernel-desktop-mode -1)
      (should-not lispm-kernel-sessions-mode))))

(ert-deftest lispm-kernel-desktop-unload-gives-sessions-back ()
  (lispm-kernel-desktop-test--with-desktop
    (lispm-kernel-sessions-mode 1)
    (should lispm-kernel-desktop-test--readers)
    (unload-feature 'lispm-kernel-desktop t)
    (should-not lispm-kernel-desktop-test--readers)
    (should-not (memq 'lispm-kernel-desktop-invalidate lispm-agents-reread-sessions-hook))
    (require 'lispm-kernel-desktop)))

(provide 'lispm-kernel-desktop-test)
;;; lispm-kernel-desktop-test.el ends here
