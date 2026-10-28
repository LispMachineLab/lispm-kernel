;;; lispm-kernel-test.el --- Emacs and the kernel program -*- lexical-binding: t; -*-

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

;; These run the kernel program LISPM_KERNEL_PROGRAM names, as `make
;; test-emacs' builds it.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lispm-kernel)
(require 'lispm-kernel-sessions)

(defconst lispm-kernel-test-program
  (or (getenv "LISPM_KERNEL_PROGRAM") (error "Set LISPM_KERNEL_PROGRAM to the kernel program"))
  "The kernel program the tests run.")

(defmacro lispm-kernel-test--with-runtime (runtime &rest body)
  "Run BODY with RUNTIME a kernel of the program under test, stopped after."
  (declare (indent 1))
  `(let ((,runtime (lispm-kernel-start lispm-kernel-test-program)))
     (unwind-protect (progn ,@body)
       (lispm-kernel-stop ,runtime))))

(defun lispm-kernel-test--wait (runtime predicate &optional seconds)
  "Take in RUNTIME's messages until PREDICATE is true, at most SECONDS."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.005)
      (lispm-kernel-dispatch runtime))
    (funcall predicate)))

(defun lispm-kernel-test--collect (runtime job input &rest options)
  "Submit JOB with INPUT to RUNTIME and return what its callback heard, in
order, once it ended."
  (let* ((heard nil)
         (ended nil)
         (id (apply #'lispm-kernel-submit runtime job input
                    :on-result (lambda (kind value)
                                 (push (list kind value) heard)
                                 (unless (eq kind 'chunk) (setq ended t)))
                    options)))
    (should (integerp id))
    (should (lispm-kernel-test--wait runtime (lambda () ended)))
    (nreverse heard)))

(defun lispm-kernel-test--stats-until (runtime predicate)
  "Ask RUNTIME's kernel for its stats until PREDICATE is true of them;
return the last."
  (let ((deadline (+ (float-time) 5)) stats)
    (while (and (not (and stats (funcall predicate stats))) (< (float-time) deadline))
      (let (answer)
        (lispm-kernel-stats runtime (lambda (plist) (setq answer plist)))
        (lispm-kernel-test--wait runtime (lambda () answer))
        (setq stats answer)
        (accept-process-output nil 0.01)))
    stats))

(ert-deftest lispm-kernel-says-hello ()
  (lispm-kernel-test--with-runtime runtime
    (should (lispm-kernel-test--wait runtime (lambda () (lispm-kernel-runtime-hello runtime))))
    (let ((hello (lispm-kernel-runtime-hello runtime)))
      (should (eql (plist-get hello :protocol) lispm-kernel-protocol))
      (should (natnump (plist-get hello :pid)))
      (should (string-prefix-p "SBCL " (plist-get hello :lisp)))
      (should (memq :scan-sessions (plist-get hello :jobs))))
    (should (lispm-kernel-live-p runtime))))

(ert-deftest lispm-kernel-data-go-there-and-back ()
  (lispm-kernel-test--with-runtime runtime
    (let ((data (list "plain" "a\nb\r\n" "q\"u\\o" (string 0 1 9 27 31 127) "\\x41\\ B"
                      (string #xe9 #x3bb #x1f600) "" -7 (expt 2 70) nil t :keyword
                      [1 "two" [3]] '(nested (list "x")))))
      ;; Plain symbols come back as keywords: the kernel reads them so.
      (should (equal (lispm-kernel-test--collect runtime 'echo data)
                     `((success ,(cl-subst :list 'list (cl-subst :nested 'nested data)))))))
    ;; Quoted forms go as they are, strings without their text properties.
    (should (equal (lispm-kernel-test--collect runtime 'echo `(a 'b #'c ,(propertize "/tmp/x" 'face 'bold)))
                   '((success (:a (:quote :b) (:function :c) "/tmp/x")))))
    (should-not (text-properties-at 0 (nth 3 (cadr (car (lispm-kernel-test--collect
                                                         runtime 'echo (list 1 2 3 (propertize "p" 'face 'bold))))))))))

(defun lispm-kernel-test--nested (depth)
  "Return a list holding a list, DEPTH deep."
  (let ((datum 1))
    (dotimes (_ depth) (setq datum (list datum)))
    datum))

(ert-deftest lispm-kernel-chunks-then-one-end ()
  (lispm-kernel-test--with-runtime runtime
    (should (equal (lispm-kernel-test--collect runtime 'wait '(:chunks 4))
                   '((chunk 0) (chunk 1) (chunk 2) (chunk 3) (success 0))))
    (should (equal (lispm-kernel-test--collect runtime 'wait '(:fail "it broke"))
                   '((failed "it broke"))))
    (should (equal (lispm-kernel-test--collect runtime 'no-such-job nil)
                   '((rejected unknown-job))))))

(ert-deftest lispm-kernel-refuses-what-cannot-go ()
  (lispm-kernel-test--with-runtime runtime
    (should-error (lispm-kernel-submit runtime 'echo 1.5))
    (should-error (lispm-kernel-submit runtime 'echo (intern "a b")))
    (should-error (lispm-kernel-submit runtime 'echo '(1 . 2)))
    (should-error (lispm-kernel-submit runtime 'echo (make-hash-table)))
    (should-error (lispm-kernel-submit runtime 'echo nil :priority 1000))
    ;; Symbols the kernel would read as numbers, or escaped.
    (dolist (symbol (list '1+ '1- 'e1 (intern "-2") (intern "?x") (intern "a.b") (intern "")))
      (should-error (lispm-kernel-submit runtime 'echo (list symbol))))
    ;; Deeper than the kernel's reader reads.
    (should-error (lispm-kernel-submit runtime 'echo (lispm-kernel-test--nested 64)))
    (should (zerop (hash-table-count (lispm-kernel-runtime-requests runtime))))
    (should (equal (lispm-kernel-test--collect runtime 'echo (lispm-kernel-test--nested 63))
                   `((success ,(lispm-kernel-test--nested 63)))))
    (should (equal (lispm-kernel-test--collect runtime 'echo '(a1 x+ :k-2 -))
                   '((success (:a1 :x+ :k-2 :-))))))
  ;; What Emacs cannot stop: a malformed submission still ends.
  (lispm-kernel-test--with-runtime runtime
    (let (heard)
      (cl-letf (((symbol-function 'lispm-kernel--wire-p) (lambda (&rest _) t)))
        (lispm-kernel-submit runtime 'echo 1.5 :on-result (lambda (kind value) (push (list kind value) heard))))
      (should (lispm-kernel-test--wait runtime (lambda () heard)))
      (should (equal heard '((rejected malformed))))
      (should (eq (car (lispm-kernel-runtime-last-error runtime)) 'protocol-error)))))

(ert-deftest lispm-kernel-a-failed-send-makes-no-request ()
  (lispm-kernel-test--with-runtime runtime
    (let (result)
      (cl-letf (((symbol-function 'process-send-string)
                 (lambda (&rest _) (error "Process lispm-kernel not running"))))
        (should-error (lispm-kernel-submit runtime 'echo 1))
        (should (zerop (hash-table-count (lispm-kernel-runtime-requests runtime))))
        ;; A scan falls back to the caller's own reader.
        (should-not (lispm-kernel-scan-sessions runtime 'claude temporary-file-directory
                                                (lambda (sessions summary) (setq result (list sessions summary)))
                                                :fallback (lambda () '((:id "own"))))))
      (with-timeout (5) (while (not result) (accept-process-output nil 0.01)))
      (should (equal (car result) '((:id "own"))))
      (should (eq (car (plist-get (cadr result) :native-error)) 'kernel-not-running)))))

(ert-deftest lispm-kernel-cancel-and-timeout ()
  (lispm-kernel-test--with-runtime runtime
    (let (heard)
      (let ((id (lispm-kernel-submit runtime 'wait '(:milliseconds 5000)
                                     :on-result (lambda (kind _) (push kind heard)))))
        (lispm-kernel-cancel runtime id))
      (should (lispm-kernel-test--wait runtime (lambda () heard)))
      (should (equal heard '(cancelled))))
    (let ((started (float-time)))
      (should (equal (lispm-kernel-test--collect runtime 'wait '(:milliseconds 5000) :timeout 0.2)
                     '((timeout nil))))
      (should (< (- (float-time) started) 3)))
    ;; The kernel was told: the request it cancelled is no more.
    (let ((stats (lispm-kernel-test--stats-until
                  runtime (lambda (stats) (= 0 (plist-get stats :requests))))))
      (should (= 2 (plist-get stats :cancelled)))
      (should (= 0 (plist-get stats :requests))))))

(ert-deftest lispm-kernel-superseded-callbacks-hear-nothing ()
  (lispm-kernel-test--with-runtime runtime
    (let (old)
      (lispm-kernel-submit runtime 'wait '(:chunks 1 :milliseconds 5000) :owner 3 :generation 1
                           :on-result (lambda (kind _) (push kind old)))
      (lispm-kernel-test--wait runtime (lambda () old))
      (lispm-kernel-supersede runtime 3 2)
      (should (equal (lispm-kernel-test--collect runtime 'echo "new" :owner 3 :generation 2)
                     '((success "new"))))
      (should-error (lispm-kernel-submit runtime 'echo "older" :owner 3 :generation 1))
      ;; The old request was cancelled in the kernel, unheard here.
      (should (= 1 (plist-get (lispm-kernel-test--stats-until
                               runtime (lambda (stats) (= 1 (plist-get stats :cancelled))))
                              :cancelled)))
      (should (equal old '(chunk))))))

(ert-deftest lispm-kernel-a-kernel-that-exits-loses-its-requests ()
  (lispm-kernel-test--with-runtime runtime
    (let (heard)
      (lispm-kernel-submit runtime 'wait '(:milliseconds 5000)
                           :on-result (lambda (kind _) (push kind heard)))
      (lispm-kernel-test--wait runtime (lambda () (lispm-kernel-runtime-hello runtime)))
      (signal-process (lispm-kernel-runtime-process runtime) 'KILL)
      (should (lispm-kernel-test--wait runtime (lambda () heard)))
      (should (equal heard '(lost)))
      (should-not (lispm-kernel-live-p runtime))
      (should (string-match-p "exited" (lispm-kernel-runtime-last-error runtime)))
      (should-error (lispm-kernel-submit runtime 'echo 1)))))

(ert-deftest lispm-kernel-stop-ends-quietly ()
  (let ((runtime (lispm-kernel-start lispm-kernel-test-program))
        heard)
    (lispm-kernel-submit runtime 'wait '(:milliseconds 5000)
                         :on-result (lambda (kind _) (push kind heard)))
    (lispm-kernel-stop runtime)
    (accept-process-output nil 0.05)
    (should-not heard)
    (should-not (process-live-p (lispm-kernel-runtime-process runtime)))
    (should-not (memq runtime lispm-kernel--runtimes))
    (should-not (lispm-kernel-pending-p runtime))))

(ert-deftest lispm-kernel-refuses-another-protocol ()
  (let ((program (make-temp-file "lispm-kernel-other" nil nil
                                 "#!/bin/sh\necho '(hello :protocol 99)'\ncat >/dev/null\n"))
        heard)
    (set-file-modes program #o755)
    (unwind-protect
        (let ((runtime (lispm-kernel-start program)))
          (unwind-protect
              (progn
                (lispm-kernel-submit runtime 'echo 1 :on-result (lambda (kind _) (push kind heard)))
                (should (lispm-kernel-test--wait runtime (lambda () heard)))
                (should (equal heard '(lost)))
                (should (string-match-p "protocol 99" (lispm-kernel-runtime-last-error runtime)))
                (should-not (lispm-kernel-live-p runtime)))
            (lispm-kernel-stop runtime)))
      (delete-file program))))

(ert-deftest lispm-kernel-dispatch-in-slices ()
  (lispm-kernel-test--with-runtime runtime
    (lispm-kernel-test--wait runtime (lambda () (lispm-kernel-runtime-hello runtime)))
    (let ((lispm-kernel-scheduler (lambda (_) t))
          (heard nil)
          (errors 0))
      (lispm-kernel-submit runtime 'wait '(:chunks 20)
                           :on-result (lambda (kind _)
                                        (push kind heard)
                                        (when (= (length heard) 3)
                                          (cl-incf errors)
                                          (error "A callback failing"))))
      ;; The scheduler takes the runtime: no timer of its own.
      (while (< (length (lispm-kernel-runtime-incoming runtime)) 21)
        (accept-process-output nil 0.01))
      (should-not (lispm-kernel-runtime-timer runtime))
      (let ((lispm-kernel-slice-seconds 0))
        ;; At least one message a slice, however small, and only one at 0.
        (lispm-kernel-dispatch runtime)
        (should (= 1 (length heard)))
        (lispm-kernel-dispatch runtime))
      (lispm-kernel-test--wait runtime (lambda () (memq 'success heard)))
      (should (= 21 (length heard)))
      (should (= 1 errors))
      (should (equal (lispm-kernel-runtime-last-error runtime) '(error "A callback failing"))))))

(ert-deftest lispm-kernel-ping ()
  (lispm-kernel-test--with-runtime runtime
    (let (pong)
      (lispm-kernel-ping runtime (lambda (data) (setq pong data)) 1 "two" :three)
      (should (lispm-kernel-test--wait runtime (lambda () pong)))
      (should (equal pong '(1 "two" :three))))))

(ert-deftest lispm-kernel-unload-stops-kernels ()
  (let ((runtime (lispm-kernel-start lispm-kernel-test-program)))
    (lispm-kernel-unload-function)
    (should (lispm-kernel-runtime-closed runtime))
    (should-not (process-live-p (lispm-kernel-runtime-process runtime)))))

;;;; Sessions

(defun lispm-kernel-test--codex (directory id cwd prompt &optional stamp)
  "Write Codex transcript ID in DIRECTORY; return its file."
  (let ((file (expand-file-name (format "2026/10/21/rollout-%s.jsonl" id) directory)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file
      (insert (json-serialize `(:type "session_meta"
                                :payload (:id ,id :cwd ,cwd :timestamp ,(or stamp "2026-10-21T01:02:03.456Z"))))
              "\n"
              (json-serialize `(:type "event_msg" :payload (:type "user_message" :message ,prompt)))
              "\n"))
    file))

(ert-deftest lispm-kernel-sessions-as-the-desktop-has-them ()
  (let ((directory (make-temp-file "lispm-kernel-sessions" t))
        result)
    (unwind-protect
        (lispm-kernel-test--with-runtime runtime
          (let ((file (lispm-kernel-test--codex directory "x" "/w/x" "first\nprompt")))
            (lispm-kernel-scan-sessions runtime 'codex directory
                                        (lambda (sessions summary) (setq result (list sessions summary))))
            (should (lispm-kernel-test--wait runtime (lambda () result)))
            (pcase-let ((`(,sessions ,summary) result))
              (should (equal (plist-get summary :rows) 1))
              (should (equal sessions
                             (list (list :agent 'codex :id "x" :cwd "/w/x" :title "first\nprompt"
                                         :started (float-time (parse-iso8601-time-string
                                                               "2026-10-21T01:02:03.456Z"))
                                         :file file
                                         ;; As `file-attributes' has it, to the nanosecond.
                                         :time (float-time (file-attribute-modification-time
                                                            (file-attributes file)))
                                         :turn-ended nil)))))))
      (delete-directory directory t))))

(ert-deftest lispm-kernel-sessions-under-their-parents ()
  "A row naming the thread or session that started its session keeps it
as the session's :parent; a parent that is no id is none."
  (should (equal (plist-get (lispm-kernel-sessions--session
                             'claude '(:id "agent-a1" :cwd "/w" :title "Find it" :file "/t/agent-a1.jsonl"
                                           :mtime 1700000000000000000 :turn-ended t :parent "s1"))
                            :parent)
                 "s1"))
  (should (equal (plist-get (lispm-kernel-sessions--session
                             'codex '(:id "f" :cwd "/w" :title "review" :file "/t/rollout-f.jsonl"
                                          :mtime 1700000000000000000 :parent "b"))
                            :parent)
                 "b"))
  (should-not (plist-member (lispm-kernel-sessions--session
                             'codex '(:id "b" :cwd "/w" :title "hello" :file "/t/rollout-b.jsonl"
                                          :mtime 1700000000000000000))
                            :parent))
  (should-not (plist-member (lispm-kernel-sessions--session
                             'claude '(:id "s1" :cwd "/w" :title "first" :file "/t/s1.jsonl"
                                           :mtime 1700000000000000000 :parent 7))
                            :parent)))

(ert-deftest lispm-kernel-sessions-fall-back ()
  (let ((directory (make-temp-file "lispm-kernel-sessions" t))
        result)
    (unwind-protect
        (progn
          ;; No kernel running.
          (lispm-kernel-scan-sessions nil 'claude directory
                                      (lambda (sessions summary) (setq result (list sessions summary)))
                                      :fallback (lambda () '((:id "own"))))
          (should-not result)
          (with-timeout (5) (while (not result) (accept-process-output nil 0.01)))
          (should (equal result '(((:id "own")) (:source elisp :native-error kernel-not-running))))
          (setq result nil)
          ;; A root the kernel cannot read.
          (lispm-kernel-test--with-runtime runtime
            (lispm-kernel-scan-sessions runtime 'codex (expand-file-name "missing" directory)
                                        (lambda (sessions summary) (setq result (list sessions summary)))
                                        :fallback (lambda () '((:id "own"))))
            (should (lispm-kernel-test--wait runtime (lambda () result)))
            (should (equal (car result) '((:id "own"))))
            (should (eq (car (plist-get (cadr result) :native-error)) 'failed)))
          (setq result nil)
          ;; Superseded before it falls back: nothing is heard.
          (lispm-kernel-test--with-runtime runtime
            (lispm-kernel-scan-sessions runtime 'codex (expand-file-name "missing" directory)
                                        (lambda (sessions summary) (setq result (list sessions summary)))
                                        :owner 5 :generation 1
                                        :fallback (lambda () '((:id "own"))))
            (lispm-kernel-supersede runtime 5 2)
            (lispm-kernel-test--wait runtime #'ignore 0.3)
            (should-not result)))
      (delete-directory directory t))))

(provide 'lispm-kernel-test)
;;; lispm-kernel-test.el ends here
