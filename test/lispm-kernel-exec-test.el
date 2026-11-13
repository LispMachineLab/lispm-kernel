;;; lispm-kernel-exec-test.el --- Programs run in the kernel -*- lexical-binding: t; -*-

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

;; These run the kernel program LISPM_KERNEL_PROGRAM names, and /bin/sh
;; scripts in it and in Emacs, which should come out the same.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lispm-kernel-test)
(require 'lispm-kernel-exec)

(defvar lispm-exec-function)

(defconst lispm-kernel-exec-test--script
  "printf '%s|%s|' \"$(pwd -P)\" \"$FOO\"; printf 'said %s' \"$BAR\" >&2; cat; exit 4"
  "A script printing where it runs, what FOO is, BAR on its standard
error, and its input, then exiting with 4.")

(defun lispm-kernel-exec-test--run (runtime function &rest arguments)
  "Call FUNCTION with ARGUMENTS and a callback; return what the callback
got once it did, taking in RUNTIME's messages meanwhile."
  (let (heard)
    (apply function (append arguments (list (lambda (&rest got) (setq heard got)))))
    (should (lispm-kernel-test--wait runtime (lambda () heard)))
    heard))

(defmacro lispm-kernel-exec-test--with (spec &rest body)
  "Run BODY with RUNTIME a kernel of the program under test, the one
`lispm-kernel-exec' uses, and LOCAL the programs Emacs ran itself, a list
counted as it runs them.  SPEC is (RUNTIME LOCAL)."
  (declare (indent 1))
  (pcase-let ((`(,runtime ,local) spec))
    `(lispm-kernel-test--with-runtime ,runtime
       (let ((lispm-kernel-exec-runtime-function (lambda () ,runtime))
             (,local nil))
         (lispm-kernel-test--wait ,runtime (lambda () (lispm-kernel-runtime-hello ,runtime)))
         (advice-add 'lispm-kernel-exec-locally :before
                     (lambda (program &rest _) (push program ,local))
                     '((name . lispm-kernel-exec-test--count)))
         (unwind-protect (progn ,@body)
           (advice-remove 'lispm-kernel-exec-locally 'lispm-kernel-exec-test--count))))))

(defun lispm-kernel-exec-test--script (directory)
  "Run the script in DIRECTORY with `lispm-kernel-exec', its environment
holding FOO and BAR; return a function that does, given a callback."
  (lambda (callback)
    (let ((default-directory (file-name-as-directory directory))
          (process-environment (append '("FOO=foo λ" "BAR=bar" "FOO=hidden") process-environment)))
      (lispm-kernel-exec "sh" (list "-c" lispm-kernel-exec-test--script) callback :input "in \u4e2d"))))

(ert-deftest lispm-kernel-exec-environment ()
  (let ((process-environment '("A=1" "B" "A=2" "B=3" "C=4=5" "PWD=/elsewhere")))
    (should (equal '("PWD=/here" "A=1" "C=4=5") (lispm-kernel-exec--environment "/here/")))))

(ert-deftest lispm-kernel-exec-in-the-kernel-as-in-emacs ()
  (let* ((directory (make-temp-file "lispm-kernel-exec-test" t))
         (run (lispm-kernel-exec-test--script directory))
         (expected (list 4 (format "%s|foo λ|in \u4e2d" (file-truename directory)) "said bar")))
    (unwind-protect
        (lispm-kernel-exec-test--with (runtime local)
          (should (equal expected (lispm-kernel-exec-test--run runtime run)))
          (should-not local)
          ;; Without a kernel knowing the job, Emacs runs it, the same.
          (let ((lispm-kernel-exec-runtime-function (lambda () nil)))
            (should (equal expected (lispm-kernel-exec-test--run runtime run))))
          (should (equal '("sh") local))
          (let ((hello (lispm-kernel-runtime-hello runtime)))
            (unwind-protect
                (progn (setf (lispm-kernel-runtime-hello runtime) (plist-put (copy-sequence hello) :jobs '(:echo)))
                       (should (equal expected (lispm-kernel-exec-test--run runtime run))))
              (setf (lispm-kernel-runtime-hello runtime) hello)))
          (should (equal '("sh" "sh") local)))
      (delete-directory directory t))))

(ert-deftest lispm-kernel-exec-what-does-not-run-or-exit ()
  (lispm-kernel-exec-test--with (runtime local)
    (let ((default-directory temporary-file-directory))
      ;; A signal, in the kernel and in Emacs alike.
      (should (equal '("sh ended by signal 15" "" "")
                     (lispm-kernel-exec-test--run runtime #'lispm-kernel-exec "sh" '("-c" "kill -TERM $$"))))
      (should (equal '("sh ended by signal 15" "" "")
                     (lispm-kernel-exec-test--run runtime #'lispm-kernel-exec-locally
                                                  "sh" '("-c" "kill -TERM $$"))))
      ;; A program not found is Emacs's to say, after this returns.
      (let* ((heard nil)
             (returned (progn (lispm-kernel-exec "lispm-no-such-program" nil
                                                 (lambda (&rest got) (setq heard got)))
                              heard)))
        (should-not returned)
        (should (lispm-kernel-test--wait runtime (lambda () heard)))
        (should (stringp (car heard)))
        (should (equal '("" "") (cdr heard))))
      (should (member "lispm-no-such-program" local))
      ;; A program past its time, stopped by the kernel.
      (let ((lispm-kernel-exec-timeout 1))
        (pcase-let ((`(,exit ,output ,_) (lispm-kernel-exec-test--run
                                          runtime #'lispm-kernel-exec "sh" '("-c" "echo began; sleep 30"))))
          (should (string-match-p "did not finish" exit))
          (should (equal "began\n" output)))))))

(ert-deftest lispm-kernel-exec-locally-program-gone-before-its-input-ends ()
  ;; As diff may be, which reads no input: it calls back once, later.
  (let ((heard nil)
        (send-eof (symbol-function 'process-send-eof))
        (default-directory temporary-file-directory))
    (cl-letf (((symbol-function 'process-send-eof)
               (lambda (&optional process)
                 ;; Gone first: waiting so takes in no event.
                 (let ((deadline (+ (float-time) 5)))
                   (while (and (process-live-p process) (< (float-time) deadline))))
                 (funcall send-eof process))))
      (lispm-kernel-exec-locally "sh" '("-c" "printf done; exit 3") (lambda (&rest got) (push got heard))))
    (should-not heard)
    (let ((deadline (+ (float-time) 10)))
      (while (and (not heard) (< (float-time) deadline))
        (accept-process-output nil 0.005)))
    (accept-process-output nil 0.1)
    (should (equal '((3 "done" "")) heard))))

(ert-deftest lispm-kernel-exec-turned-away-runs-in-emacs ()
  (lispm-kernel-exec-test--with (runtime local)
    (let ((default-directory temporary-file-directory))
      (cl-letf (((symbol-function 'lispm-kernel-submit)
                 (lambda (&rest arguments)
                   (run-at-time 0 nil (plist-get arguments :on-result) 'rejected 'capacity)
                   1)))
        (should (equal '(0 "x" "") (lispm-kernel-exec-test--run runtime #'lispm-kernel-exec "echo" '("-n" "x"))))
        (should (equal '("echo") local))))))

(ert-deftest lispm-kernel-exec-mode-runs-lispm-programs ()
  (let ((had (boundp 'lispm-exec-function))
        (old (bound-and-true-p lispm-exec-function))
        (ran nil))
    (unwind-protect
        (progn
          (setq lispm-exec-function (lambda (program &rest _) (push program ran)))
          (lispm-kernel-exec-test--with (runtime local)
            (let ((default-directory temporary-file-directory))
              (lispm-kernel-exec-mode 1)
              (should (equal '(0 "y" "")
                             (lispm-kernel-exec-test--run runtime lispm-exec-function "echo" '("-n" "y"))))
              (should-not ran)
              (should-not local)
              ;; Without the kernel, as without the mode.
              (let ((lispm-kernel-exec-runtime-function (lambda () nil)))
                (funcall lispm-exec-function "echo" '("z") #'ignore))
              (should (equal '("echo") ran))
              (lispm-kernel-exec-mode -1)
              (funcall lispm-exec-function "true" nil #'ignore)
              (should (equal '("true" "echo") ran)))))
      (lispm-kernel-exec-mode -1)
      (if had (setq lispm-exec-function old) (makunbound 'lispm-exec-function)))))

(ert-deftest lispm-kernel-exec-streams-on-output ()
  (lispm-kernel-exec-test--with (runtime _local)
    (let ((default-directory temporary-file-directory)
          (chunks nil)
          (local-chunks nil))
      (pcase-let ((`(,exit ,output ,said)
                   (lispm-kernel-exec-test--run
                    runtime
                    (lambda (cb)
                      (lispm-kernel-exec "sh" '("-c" "printf 'one\n'; printf 'two\n'; printf 'err' >&2")
                                         cb
                                         :on-output (lambda (c) (push c chunks)))))))
        (should (eql 0 exit))
        (should (equal "one\ntwo\n" output))
        (should (equal "err" said))
        (should (equal "one\ntwo\n" (apply #'concat (nreverse chunks)))))
      (let ((heard nil))
        (lispm-kernel-exec-locally "sh" '("-c" "printf 'alpha\n'")
                                   (lambda (&rest got) (setq heard got))
                                   :on-output (lambda (c) (push c local-chunks)))
        (let ((deadline (+ (float-time) 5)))
          (while (and (not heard) (< (float-time) deadline))
            (accept-process-output nil 0.01)))
        (should (equal '(0 "alpha\n" "") heard))
        (should (equal "alpha\n" (apply #'concat (nreverse local-chunks))))))))

(ert-deftest lispm-kernel-http-stream-and-search-files ()
  (let ((dir (make-temp-file "lispm-kernel-search-test" t)))
    (unwind-protect
        (lispm-kernel-exec-test--with (runtime _local)
          (let ((file-a (expand-file-name "a.txt" dir))
                (file-b (expand-file-name "b.txt" dir)))
            (with-temp-file file-a (insert "hello kernel\nsecond line\n"))
            (with-temp-file file-b (insert "open buffer on disk\n"))
            (let ((search-got nil))
              (should (functionp
                       (lispm-kernel-search-files
                        (list (file-name-as-directory dir))
                        "kernel"
                        nil
                        (lambda (res) (setq search-got res))
                        :open-files (list file-b))))
              (should (lispm-kernel-test--wait runtime (lambda () search-got)))
              (should (equal 0 (plist-get search-got :large)))
              (let ((items (plist-get search-got :items)))
                (should (equal (list :file file-a
                                     :matches '((1 "hello kernel")))
                               (assoc-default file-a
                                              (mapcar (lambda (it) (cons (plist-get it :file) it))
                                                      items))))
                (should (equal (list :file file-b :open t)
                               (assoc-default file-b
                                              (mapcar (lambda (it) (cons (plist-get it :file) it))
                                                      items))))))
            (let ((http-got nil)
                  (chunks nil))
              (should (functionp
                       (lispm-kernel-http-stream
                        (concat "file://" (file-truename file-a))
                        '("X-Test: 1")
                        "{}"
                        (lambda (c) (push c chunks))
                        (lambda (out) (setq http-got out)))))
              (should (lispm-kernel-test--wait runtime (lambda () http-got)))
              (should (string-match-p "hello kernel" http-got))
              (should (string-match-p "hello kernel" (apply #'concat (nreverse chunks)))))))
      (delete-directory dir t))))

(ert-deftest lispm-kernel-remote-ssh-host-exec-and-search-files ()
  (should (equal "/ssh:dev@example.com:" (lispm-kernel-ssh-host "/ssh:dev@example.com:/tmp/work")))
  (should (equal "/scp:dev@example.com#2222:" (lispm-kernel-ssh-host "/scp:dev@example.com#2222:/tmp/work")))
  (should-not (lispm-kernel-ssh-host "/sudo::/etc/hosts"))
  (should-not (lispm-kernel-ssh-host "/tmp/local"))
  (should (equal "x86_64-unknown-linux-gnu" (lispm-kernel-program-uname-target "Linux\n" "x86_64\n")))
  (should (equal "aarch64-apple-darwin" (lispm-kernel-program-uname-target "Darwin" "arm64")))
  (should (equal '("ssh" "-T" "-o" "BatchMode=yes" "-p" "2222" "-l" "dev" "--" "example.com")
                 (lispm-kernel-program-ssh-args "/ssh:dev@example.com#2222:/tmp")))
  (let* ((dir (make-temp-file "lispm-kernel-remote-test" t))
         (host "/ssh:dev@example.com:")
         (remote-dir (concat host (file-name-as-directory dir)))
         (runtime (lispm-kernel-start (list lispm-kernel-test-program) host)))
    (unwind-protect
        (progn
          (should (lispm-kernel-test--wait runtime (lambda () (lispm-kernel-runtime-hello runtime))))
          (let ((lispm-kernel-exec-runtime-function
                 (lambda (&optional target-dir)
                   (and (lispm-kernel-same-host-p runtime target-dir) runtime))))
            ;; Remote `exec' strips the TRAMP prefix for :cwd, resolves bare commands
            ;; on the remote host via :search t, and merges dynamic env overrides.
            (let ((default-directory remote-dir)
                  (process-environment (cons "LISPM_REMOTE_VAR=ok" process-environment)))
              (pcase-let ((`(,exit ,output ,said)
                           (lispm-kernel-exec-test--run
                            runtime #'lispm-kernel-exec
                            "sh" '("-c" "printf '%s|%s' \"$PWD\" \"$LISPM_REMOTE_VAR\""))))
                (should (eql 0 exit))
                (should (equal (concat (directory-file-name dir) "|ok") output))
                (should (equal "" said))))
            ;; Remote `search-files' strips the TRAMP prefix on input and re-attaches
            ;; it to returned `:file' paths and `:open-files' markers.
            (let ((local-a (expand-file-name "a.txt" dir))
                  (local-b (expand-file-name "b.txt" dir))
                  (remote-a (concat remote-dir "a.txt"))
                  (remote-b (concat remote-dir "b.txt"))
                  (search-got nil))
              (with-temp-file local-a (insert "remote match line\n"))
              (with-temp-file local-b (insert "modified on remote\n"))
              (should (functionp
                       (lispm-kernel-search-files
                        (list remote-dir)
                        "remote"
                        nil
                        (lambda (res) (setq search-got res))
                        :open-files (list remote-b))))
              (should (lispm-kernel-test--wait runtime (lambda () search-got)))
              (let ((items (plist-get search-got :items)))
                (should (equal (list :file remote-a :matches '((1 "remote match line")))
                               (assoc-default remote-a
                                              (mapcar (lambda (it) (cons (plist-get it :file) it))
                                                      items))))
                (should (equal (list :file remote-b :open t)
                               (assoc-default remote-b
                                              (mapcar (lambda (it) (cons (plist-get it :file) it))
                                                      items))))))))
      (lispm-kernel-stop runtime)
      (delete-directory dir t))))

(provide 'lispm-kernel-exec-test)
;;; lispm-kernel-exec-test.el ends here
