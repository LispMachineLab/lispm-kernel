;;; lispm-kernel-desktop-test.el --- Opt-in integration against desktop -*- lexical-binding: t; -*-

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
;; Integration with a LispM Desktop that has session readers and a frame
;; clock.  Load after lispm-kernel-test.el, which loads the module and
;; defines `lispm-kernel-test--finish'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lispm-kernel-desktop)
(require 'lispm-desktop-agent-codex)
(require 'lispm-desktop-agent-claude)
;; Loaded before any test fakes their functions: loading them later would
;; replace the fakes, and undoing a fake would then unbind the real ones.
(require 'lispm-desktop-ai)
(require 'lispm-desktop-frame)
(declare-function lispm-kernel-test--finish "lispm-kernel-test" (runtime))

(defvar lispm-kernel-desktop-test--readers nil
  "Readers the faked desktop registry holds, an alist (AGENT . READER).")
(defvar lispm-kernel-desktop-test--arrived 0
  "How often `lispm-desktop-agent-sessions-arrived' was called.")

(defmacro lispm-kernel-desktop-test--with-desktop (&rest body)
  "Run BODY with the desktop's reader registry recorded, then turn the mode off."
  (declare (indent 0))
  `(let ((lispm-kernel-desktop-test--readers nil)
         (lispm-kernel-desktop-test--arrived 0))
     (cl-letf (((symbol-function 'lispm-desktop-agent-add-session-reader)
                (lambda (agent reader)
                  (setf (alist-get agent lispm-kernel-desktop-test--readers) reader)))
               ((symbol-function 'lispm-desktop-agent-remove-session-reader)
                (lambda (agent)
                  (setf (alist-get agent lispm-kernel-desktop-test--readers nil t) nil)))
               ((symbol-function 'lispm-desktop-agent-sessions-arrived)
                (lambda () (cl-incf lispm-kernel-desktop-test--arrived))))
       (unwind-protect (progn ,@body)
         (lispm-kernel-desktop-mode -1)))))

(defun lispm-kernel-desktop-test--read (agent)
  "Call AGENT's registered reader."
  (funcall (alist-get agent lispm-kernel-desktop-test--readers)))

(defun lispm-kernel-desktop-test--read-until-known (agent)
  "Call AGENT's reader until it stops answering `pending'; return its sessions."
  (let ((deadline (+ (float-time) 3)) (sessions 'pending))
    (while (and (eq sessions 'pending) (< (float-time) deadline))
      (lispm-kernel-dispatch lispm-kernel-desktop--runtime)
      (setq sessions (lispm-kernel-desktop-test--read agent))
      (when (eq sessions 'pending) (sleep-for 0.001)))
    sessions))

(defun lispm-kernel-desktop-test--codex-fixture (directory)
  "Write one Codex transcript into DIRECTORY."
  (with-temp-file (expand-file-name "rollout-test.jsonl" directory)
    (insert "{\"type\":\"session_meta\",\"payload\":{\"id\":\"id\",\"cwd\":\"/test\",\"timestamp\":\"2026-10-21T00:00:00Z\"}}\n"
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"same title\"}}\n")))

(ert-deftest lispm-kernel-desktop-reader-is-eventually-equivalent-and-reversible ()
  (let* ((directory (make-temp-file "lispm-desktop-integration-" t))
         (lispm-desktop-agent-codex-sessions-directory directory)
         (lispm-desktop-agent-codex-index-file (expand-file-name "missing-index.jsonl" directory))
         baseline result)
    (unwind-protect
        (lispm-kernel-desktop-test--with-desktop
          (lispm-kernel-desktop-test--codex-fixture directory)
          (setq baseline (lispm-desktop-agent-codex-sessions))
          (lispm-kernel-desktop-mode 1)
          (should (assq 'codex lispm-kernel-desktop-test--readers))
          (should (assq 'claude lispm-kernel-desktop-test--readers))
          (should (memq #'lispm-kernel-desktop-invalidate lispm-desktop-agent-reread-sessions-hook))
          (should (eq (lispm-kernel-desktop-test--read 'codex) 'pending))
          (setq result (lispm-kernel-desktop-test--read-until-known 'codex))
          (should (= (length result) 1))
          (dolist (key '(:agent :id :cwd :title :started :file :time))
            (should (equal (plist-get (car result) key) (plist-get (car baseline) key))))
          (should (> lispm-kernel-desktop-test--arrived 0))
          ;; The desktop's own reader is never advised: the picker reads it as before.
          (should (equal (lispm-desktop-agent-codex-sessions) baseline))
          ;; A fresh snapshot does not start another scan.
          (lispm-kernel-desktop-test--read 'codex)
          (should-not (lispm-kernel-pending-p lispm-kernel-desktop--runtime))
          (lispm-kernel-desktop-mode -1)
          (should-not lispm-kernel-desktop-test--readers)
          (should-not (memq #'lispm-kernel-desktop-invalidate lispm-desktop-agent-reread-sessions-hook))
          (should-not lispm-kernel-desktop--runtime))
      (delete-directory directory t))))

(ert-deftest lispm-kernel-desktop-claude-result-matches-current-parser ()
  (let* ((directory (make-temp-file "lispm-claude-parity-" t))
         (lispm-desktop-agent-claude-projects-directory directory)
         baseline result)
    (unwind-protect
        (lispm-kernel-desktop-test--with-desktop
          (make-directory (expand-file-name "project/session" directory) t)
          (with-temp-file (expand-file-name "project/session.jsonl" directory)
            (insert "{\"type\":\"user\",\"cwd\":\"/project\",\"isMeta\":true,\"message\":{\"content\":\"ignore me\"}}\n"
                    "{\"type\":\"user\",\"cwd\":\"/project\",\"message\":{\"content\":[{\"text\":\"hello\"}]}}\n"
                    "{\"type\":\"summary\",\"summary\":\"summary title\"}\n"))
          (with-temp-file (expand-file-name "project/session/custom-title.json" directory)
            (insert "{\"customTitle\":\"overridden title\"}"))
          (setq baseline (lispm-desktop-agent-claude-sessions))
          (lispm-kernel-desktop-mode 1)
          (setq result (lispm-kernel-desktop-test--read-until-known 'claude))
          (should (= (length result) 1))
          (dolist (key '(:agent :id :cwd :title :file :time))
            (should (equal (plist-get (car result) key) (plist-get (car baseline) key)))))
      (delete-directory directory t))))

(ert-deftest lispm-kernel-desktop-reread-supersedes-and-keeps-old-sessions ()
  (lispm-kernel-desktop-test--with-desktop
    (lispm-kernel-desktop-mode 1)
    (puthash 'codex '(:root "/r" :sessions ((:id "old")) :known t :generation 0 :time 1 :request 42)
             lispm-kernel-desktop--cache)
    (run-hooks 'lispm-desktop-agent-reread-sessions-hook)
    (let ((entry (gethash 'codex lispm-kernel-desktop--cache)))
      (should (= (plist-get entry :generation) 1))
      (should-not (plist-get entry :request))
      (should-not (plist-get entry :time))
      (should (plist-get entry :known))
      (should (equal (plist-get entry :sessions) '((:id "old")))))))

(ert-deftest lispm-kernel-desktop-reenable-retains-runtime ()
  (lispm-kernel-desktop-test--with-desktop
    (lispm-kernel-desktop-mode 1)
    (let ((runtime lispm-kernel-desktop--runtime))
      (lispm-kernel-desktop-mode 1)
      (should (eq runtime lispm-kernel-desktop--runtime)))))

(ert-deftest lispm-kernel-desktop-stays-off-without-a-module ()
  (lispm-kernel-desktop-test--with-desktop
    (cl-letf (((symbol-function 'lispm-kernel-try-create) #'ignore))
      (should-error (lispm-kernel-desktop-mode 1) :type 'user-error))
    (should-not lispm-kernel-desktop-mode)
    (should-not lispm-kernel-desktop-test--readers)
    (should-not lispm-kernel-broker--runtime)))

(ert-deftest lispm-kernel-desktop-remote-root-uses-the-desktop-reader ()
  (let ((lispm-desktop-agent-codex-sessions-directory "/ssh:host:/sessions/") called)
    (lispm-kernel-desktop-test--with-desktop
      (lispm-kernel-desktop-mode 1)
      (cl-letf (((symbol-function 'lispm-desktop-agent-codex-sessions)
                 (lambda () (setq called t) '((:id "remote")))))
        (should (equal (lispm-kernel-desktop-test--read 'codex) '((:id "remote"))))
        (should called)))))

(ert-deftest lispm-kernel-desktop-gives-up-a-request-that-never-ends ()
  (let ((lispm-kernel-desktop-scan-timeout 1))
    (should (lispm-kernel-desktop--stale-p
             (list :request 42 :started (- (float-time) 10) :time nil)))
    (should-not (lispm-kernel-desktop--stale-p
                 (list :request 42 :started (float-time) :time nil)))))

(ert-deftest lispm-kernel-desktop-retries-busy-admission-without-blocking ()
  (let* ((directory (make-temp-file "lispm-busy-" t))
         (lispm-desktop-agent-codex-sessions-directory directory)
         (lispm-desktop-agent-codex-index-file (expand-file-name "missing.jsonl" directory))
         (submit (symbol-function 'lispm-kernel-submit))
         (attempts 0))
    (unwind-protect
        (lispm-kernel-desktop-test--with-desktop
          (lispm-kernel-desktop-test--codex-fixture directory)
          (lispm-kernel-desktop-mode 1)
          (cl-letf (((symbol-function 'lispm-kernel-submit)
                     (lambda (&rest args)
                       (setq attempts (1+ attempts))
                       (if (= attempts 1) 'busy (apply submit args)))))
            (should (eq (lispm-kernel-desktop-test--read 'codex) 'pending))
            (should (= attempts 1))
            (should (eq (plist-get (gethash 'codex lispm-kernel-desktop--cache) :request) 'retry))
            (should (= (length (lispm-kernel-desktop-test--read-until-known 'codex)) 1))
            (should (> attempts 1))))
      (delete-directory directory t))))

(ert-deftest lispm-kernel-broker-runs-on-the-frame-clock ()
  (let ((runtime (lispm-kernel-create)) requests clients)
    (unwind-protect
        (cl-letf (((symbol-function 'lispm-desktop-frame-request)
                   (lambda (name) (push name requests)))
                  ((symbol-function 'lispm-desktop-frame-add-client)
                   (lambda (name function &optional depth) (push (list name function depth) clients)))
                  ((symbol-function 'lispm-desktop-frame-remove-client)
                   (lambda (name) (setq clients (assq-delete-all name clients)))))
          (lispm-kernel-broker-start runtime)
          (should (equal (car clients) (list 'lispm-kernel #'lispm-kernel-broker--frame
                                             lispm-kernel-broker-depth)))
          (should (eq lispm-kernel-scheduler #'lispm-kernel-broker--schedule))
          (lispm-kernel-test--submit runtime "x" #'ignore)
          (should (memq 'lispm-kernel requests))
          (should-not (lispm-kernel-runtime-timer runtime))
          (let (slice)
            (cl-letf (((symbol-function 'lispm-kernel-dispatch)
                       (lambda (_) (setq slice lispm-kernel-slice-seconds))))
              ;; Still waiting for its result: the clock is asked back.
              (should (lispm-kernel-broker--frame (+ (float-time) 0.005)))
              (should (< 0.004 slice 0.0051))))
          (lispm-kernel-broker-stop)
          (should-not clients)
          (should-not lispm-kernel-scheduler)
          ;; Back on its own timers while a request waits.
          (should (lispm-kernel-runtime-timer runtime)))
      (lispm-kernel-broker-stop)
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-desktop-unload-gives-sessions-back ()
  (lispm-kernel-desktop-test--with-desktop
    (lispm-kernel-desktop-mode 1)
    (should lispm-kernel-desktop-test--readers)
    (unload-feature 'lispm-kernel-desktop t)
    (should-not lispm-kernel-desktop-test--readers)
    (should-not (memq 'lispm-kernel-desktop-invalidate lispm-desktop-agent-reread-sessions-hook))
    (should-not lispm-kernel-broker--runtime)
    (require 'lispm-kernel-desktop)))

(provide 'lispm-kernel-desktop-test)
;;; lispm-kernel-desktop-test.el ends here
