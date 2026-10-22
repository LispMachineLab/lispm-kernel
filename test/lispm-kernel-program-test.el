;;; lispm-kernel-program-test.el --- The kernel program, downloaded or built -*- lexical-binding: t; -*-

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

;; Releases here are directories laid out as GitHub's, reached by file://
;; URLs, and the programs in them shell scripts that say hello.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lispm-kernel-program)

(defvar lispm-kernel-program-test--obtained nil
  "What `lispm-kernel-program-obtained-functions' were called with, newest first.")

(defconst lispm-kernel-program-test--sources
  '("lispm-kernel.asd" "scripts/build.lisp" "src/package.lisp" "src/main.lisp")
  "The stand-in sources of a test's repository.")

(defconst lispm-kernel-program-test--hello
  "#!/bin/sh\necho '(hello :protocol 1)'\ncat >/dev/null\n"
  "A program that says hello as a kernel does.")

(defmacro lispm-kernel-program-test--with-sources (&rest body)
  "Run BODY in a new repository, `root', whose sources are a minute old,
downloading as by default, as if on Apple silicon."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "lispm-kernel-program" t)))
          (lispm-kernel-program-source-directory root)
          (lispm-kernel-program-lisp-directory (expand-file-name "lisp/" root))
          (lispm-kernel-program-source 'download)
          (lispm-kernel-program-problem nil)
          (lispm-kernel-program--building nil)
          (lispm-kernel-program--downloading nil)
          (lispm-kernel-program-test--obtained nil)
          (lispm-kernel-program-obtained-functions
           (list (lambda (there) (push there lispm-kernel-program-test--obtained))))
          (system-configuration "aarch64-apple-darwin25.0.0")
          (inhibit-message t))
     (unwind-protect
         (progn
           (make-directory lispm-kernel-program-lisp-directory)
           (dolist (name lispm-kernel-program-test--sources)
             (lispm-kernel-program-test--file (expand-file-name name root) name 60))
           ,@body)
       (dolist (process (list lispm-kernel-program--building lispm-kernel-program--downloading))
         (when (process-live-p process) (delete-process process)))
       (delete-directory root t))))

(defun lispm-kernel-program-test--file (file &optional contents age)
  "Write CONTENTS to FILE, making its directory, AGE seconds old."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert (or contents "")))
  (when age
    (set-file-times file (time-subtract nil age)))
  file)

(defun lispm-kernel-program-test--pin (programs &optional version)
  "Pin PROGRAMS, an alist of target and SHA-256, for VERSION, by default
the sources'."
  (with-temp-file (lispm-kernel-program--sums-file)
    (prin1 (list :version (or version (lispm-kernel-program-source-version)) :programs programs)
           (current-buffer))))

(defun lispm-kernel-program-test--release (directory version programs)
  "Lay out the release of VERSION in DIRECTORY with PROGRAMS, an alist of
target and the program's text; return the alist of target and the
SHA-256 of what is published."
  (let ((release (expand-file-name (format "kernel-program-%s/" version) directory))
        (sums nil))
    (make-directory release t)
    (pcase-dolist (`(,target . ,text) programs)
      (let ((program (expand-file-name (concat "lispm-kernel-" target) release)))
        (with-temp-file program (insert text))
        (call-process "gzip" nil nil nil "-n" "-f" program)
        (push (cons target (lispm-kernel-program--sha256 (concat program ".gz"))) sums)))
    (with-temp-file (expand-file-name "SHA256SUMS" release)
      (pcase-dolist (`(,target . ,sha256) (reverse sums))
        (insert (format "%s  %s\n" sha256 (lispm-kernel-program--asset target)))))
    (nreverse sums)))

(defun lispm-kernel-program-test--wait ()
  (with-timeout (20 (error "Waited too long"))
    (while (lispm-kernel-program--busy-p)
      (accept-process-output nil 0.02))))

(ert-deftest lispm-kernel-program-target ()
  (should (equal (lispm-kernel-program--target "aarch64-apple-darwin25.0.0") "aarch64-apple-darwin"))
  (should (equal (lispm-kernel-program--target "arm64-apple-darwin23.1.0") "aarch64-apple-darwin"))
  (should (equal (lispm-kernel-program--target "x86_64-apple-darwin21.6.0") "x86_64-apple-darwin"))
  (should (equal (lispm-kernel-program--target "x86_64-pc-linux-gnu") "x86_64-unknown-linux-gnu"))
  (should-not (lispm-kernel-program--target "aarch64-unknown-linux-gnu"))
  (should-not (lispm-kernel-program--target "x86_64-w64-mingw32"))
  (should (equal (lispm-kernel-program--asset "x86_64-apple-darwin") "lispm-kernel-x86_64-apple-darwin.gz")))

(ert-deftest lispm-kernel-program-source-version ()
  (lispm-kernel-program-test--with-sources
    (let ((version (lispm-kernel-program-source-version)))
      (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" version))
      ;; What sha256sum makes of the sources, at the root.
      (should (equal (lispm-kernel-program-source-digest)
                     (secure-hash 'sha256
                                  (mapconcat (lambda (name)
                                               (format "%s  %s\n"
                                                       (secure-hash 'sha256 name) name))
                                             (sort (copy-sequence lispm-kernel-program-test--sources)
                                                   #'string<)
                                             ""))))
      ;; Files that are no sources leave it as it is; a source changes it.
      (lispm-kernel-program-test--file (expand-file-name "README.md" root) "words")
      (lispm-kernel-program-test--file (expand-file-name "build/lispm-kernel" root) "program")
      (should (equal version (lispm-kernel-program-source-version)))
      (lispm-kernel-program-test--file (expand-file-name "src/new.lisp" root) "(new)")
      (should-not (equal version (lispm-kernel-program-source-version)))))
  (let ((lispm-kernel-program-source-directory (make-temp-file "lispm-kernel-empty" t)))
    (unwind-protect (should-not (lispm-kernel-program-source-version))
      (delete-directory lispm-kernel-program-source-directory t))))

(ert-deftest lispm-kernel-program-pins ()
  (lispm-kernel-program-test--with-sources
    (should-not (lispm-kernel-program--pinned-sha256))
    (let ((sha256 (make-string 64 ?a)))
      (lispm-kernel-program-test--pin `(("aarch64-apple-darwin" . ,sha256) ("x86_64-apple-darwin" . "short")))
      (should (equal (lispm-kernel-program--pinned-sha256) sha256))
      (should-not (lispm-kernel-program--pinned-sha256 "x86_64-apple-darwin"))
      (should-not (lispm-kernel-program--pinned-sha256 "x86_64-unknown-linux-gnu"))
      ;; Pins of other sources pin nothing for these.
      (lispm-kernel-program-test--pin `(("aarch64-apple-darwin" . ,sha256)) "0000000000000000")
      (should-not (lispm-kernel-program--pinned-sha256))
      (should (string-match-p "none is pinned" (lispm-kernel-program--why-not))))))

(ert-deftest lispm-kernel-program-downloads-checked ()
  (lispm-kernel-program-test--with-sources
    (let* ((releases (expand-file-name "releases" root))
           (version (lispm-kernel-program-source-version))
           (lispm-kernel-program-prebuilt-url (concat "file://" releases))
           (sums (lispm-kernel-program-test--release
                  releases version `(("aarch64-apple-darwin" . ,lispm-kernel-program-test--hello)))))
      (lispm-kernel-program-test--pin sums)
      ;; A program kept for older sources goes once this one is there.
      (lispm-kernel-program-test--file (expand-file-name "prebuilt/0123456789abcdef/lispm-kernel-old" root) "old")
      (should (eq (lispm-kernel-program--plan) 'download))
      (should-not (lispm-kernel-program-file))
      (should (eq (lispm-kernel-program-obtain) 'pending))
      (should (eq (lispm-kernel-program-obtain) 'pending))
      (lispm-kernel-program-test--wait)
      (should (equal lispm-kernel-program-test--obtained '(t)))
      (should-not lispm-kernel-program-problem)
      (let ((program (lispm-kernel-program-file)))
        (should (equal program (expand-file-name (format "prebuilt/%s/lispm-kernel-aarch64-apple-darwin" version)
                                                 root)))
        (should (file-executable-p program))
        (should (equal (with-temp-buffer (insert-file-contents program) (buffer-string))
                       lispm-kernel-program-test--hello))
        (should (lispm-kernel-program--check program)))
      (should-not (file-exists-p (expand-file-name "prebuilt/0123456789abcdef" root)))
      (should (eq (lispm-kernel-program-obtain) 'ready))
      (should-not (lispm-kernel-program--plan)))))

(ert-deftest lispm-kernel-program-download-refused ()
  (lispm-kernel-program-test--with-sources
    (let* ((releases (expand-file-name "releases" root))
           (version (lispm-kernel-program-source-version))
           (lispm-kernel-program-prebuilt-url (concat "file://" releases)))
      (lispm-kernel-program-test--release
       releases version `(("aarch64-apple-darwin" . ,lispm-kernel-program-test--hello)))
      ;; Pinned as another program than the one published.
      (lispm-kernel-program-test--pin `(("aarch64-apple-darwin" . ,(make-string 64 ?b))))
      (should (eq (lispm-kernel-program-obtain) 'pending))
      (lispm-kernel-program-test--wait)
      (should (equal lispm-kernel-program-test--obtained '(nil)))
      (should (string-match-p "SHA-256 differs, so it was refused" lispm-kernel-program-problem))
      (should-not (lispm-kernel-program-file))
      (should-not (file-exists-p (expand-file-name "prebuilt" root)))))
  (lispm-kernel-program-test--with-sources
    (let* ((lispm-kernel-program-prebuilt-url (concat "file://" (expand-file-name "nowhere" root))))
      (lispm-kernel-program-test--pin `(("aarch64-apple-darwin" . ,(make-string 64 ?b))))
      (should (eq (lispm-kernel-program-obtain) 'pending))
      (lispm-kernel-program-test--wait)
      (should (string-match-p "could not be downloaded" lispm-kernel-program-problem)))))

(defun lispm-kernel-program-test--fake-curl (directory script)
  "Put a curl running SCRIPT, a shell script's body, first in DIRECTORY; the
real curl is $CURL there."
  (let ((curl (expand-file-name "curl" directory)))
    (lispm-kernel-program-test--file
     curl (format "#!/bin/sh\nCURL=%s\n%s" (shell-quote-argument (executable-find "curl")) script))
    (set-file-modes curl #o755)
    directory))

(ert-deftest lispm-kernel-program-download-progress ()
  "How far the download is goes to the progress functions as curl's bar
says it; the bar's frames stay out of the download's buffer."
  (lispm-kernel-program-test--with-sources
    (let* ((releases (expand-file-name "releases" root))
           (version (lispm-kernel-program-source-version))
           (lispm-kernel-program-prebuilt-url (concat "file://" releases))
           (bin (lispm-kernel-program-test--fake-curl
                 (expand-file-name "bin" root)
                 (concat "printf '#=#=#        \\r##O#-#       \\r' >&2\n"
                         "printf '\\r###           25.0%%' >&2\n"
                         "printf '\\r######        50,0%%' >&2\n"
                         "printf '\\r############ 100.0%%\\n' >&2\n"
                         "exec \"$CURL\" --silent \"$@\"\n")))
           (exec-path (cons bin exec-path))
           (fractions nil)
           (lispm-kernel-program-progress-functions (list (lambda (fraction) (push fraction fractions)))))
      (lispm-kernel-program-test--pin
       (lispm-kernel-program-test--release
        releases version `(("aarch64-apple-darwin" . ,lispm-kernel-program-test--hello))))
      (should (eq (lispm-kernel-program-obtain) 'pending))
      (lispm-kernel-program-test--wait)
      (should (equal lispm-kernel-program-test--obtained '(t)))
      (should (equal (reverse fractions) '(0.25 0.5 1.0)))
      (should-not lispm-kernel-program-progress)
      (should-not (string-match-p "#" (with-current-buffer "*lispm-kernel download*" (buffer-string))))
      (should (lispm-kernel-program-file)))))

(ert-deftest lispm-kernel-program-download-stopped ()
  "A download stopped ends at once: nothing is kept, and those waiting hear
it is not there."
  (lispm-kernel-program-test--with-sources
    (let* ((bin (lispm-kernel-program-test--fake-curl (expand-file-name "bin" root) "sleep 30\n"))
           (exec-path (cons bin exec-path)))
      (lispm-kernel-program-test--pin `(("aarch64-apple-darwin" . ,(make-string 64 ?b))))
      (should (eq (lispm-kernel-program-obtain) 'pending))
      (should (lispm-kernel-program--busy-p))
      (lispm-kernel-program-stop)
      (should-not (lispm-kernel-program--busy-p))
      (should (equal lispm-kernel-program-test--obtained '(nil)))
      (should (string-match-p "stopped" lispm-kernel-program-problem))
      (should-not lispm-kernel-program--stopped)
      (should-not (lispm-kernel-program-file)))))

(ert-deftest lispm-kernel-program-nothing-to-download ()
  (lispm-kernel-program-test--with-sources
    (should-not (lispm-kernel-program--plan))
    (should-not (lispm-kernel-program-obtain))
    (should (string-match-p "none is pinned" lispm-kernel-program-problem))
    (let ((system-configuration "x86_64-w64-mingw32"))
      (should (string-match-p "none is published" (lispm-kernel-program--why-not))))))

(defun lispm-kernel-program-test--fake-sbcl (directory script)
  "Put an sbcl running SCRIPT, a shell script's body, first in DIRECTORY."
  (let ((sbcl (expand-file-name "sbcl" directory)))
    (lispm-kernel-program-test--file sbcl (concat "#!/bin/sh\n" script))
    (set-file-modes sbcl #o755)
    directory))

(ert-deftest lispm-kernel-program-builds-when-asked ()
  (lispm-kernel-program-test--with-sources
    (let* ((bin (lispm-kernel-program-test--fake-sbcl
                 (expand-file-name "bin" root)
                 (format "mkdir -p \"$(dirname \"$LISPM_KERNEL_OUTPUT\")\"\nprintf '%%s' %s > \"$LISPM_KERNEL_OUTPUT\"\nchmod +x \"$LISPM_KERNEL_OUTPUT\"\n"
                         (shell-quote-argument lispm-kernel-program-test--hello))))
           (exec-path (cons bin exec-path))
           (lispm-kernel-program-source 'build))
      (should (eq (lispm-kernel-program--plan) 'build))
      (should (eq (lispm-kernel-program-obtain) 'pending))
      (lispm-kernel-program-test--wait)
      (should (equal lispm-kernel-program-test--obtained '(t)))
      (should (equal (lispm-kernel-program-file) (expand-file-name "build/lispm-kernel" root)))
      (should (lispm-kernel-program--check (lispm-kernel-program-file)))
      (should-not (lispm-kernel-program--plan))
      ;; A source newer than the program: built again, the old one run meanwhile.
      (lispm-kernel-program-test--file (expand-file-name "src/main.lisp" root) "(changed)")
      (set-file-times (expand-file-name "build/lispm-kernel" root) (time-subtract nil 30))
      (should (lispm-kernel-program--stale-p))
      (should (eq (lispm-kernel-program--plan) 'build))
      (should (equal (lispm-kernel-program-file) (expand-file-name "build/lispm-kernel" root))))))

(ert-deftest lispm-kernel-program-build-fails ()
  (lispm-kernel-program-test--with-sources
    (let* ((bin (lispm-kernel-program-test--fake-sbcl (expand-file-name "bin" root)
                                                      "echo 'Warning, so no build' >&2\nexit 1\n"))
           (exec-path (cons bin exec-path))
           (lispm-kernel-program-source 'build))
      (should (eq (lispm-kernel-program-obtain) 'pending))
      (lispm-kernel-program-test--wait)
      (should (equal lispm-kernel-program-test--obtained '(nil)))
      (should (string-match-p "SBCL could not build it" lispm-kernel-program-problem))
      (should (string-match-p "no build" (with-current-buffer "*lispm-kernel build*" (buffer-string))))
      (should-not (lispm-kernel-program-file)))))

(ert-deftest lispm-kernel-program-checks-what-it-runs ()
  (let ((other (make-temp-file "lispm-kernel-other" nil nil
                               "#!/bin/sh\necho '(hello :protocol 2)'\ncat >/dev/null\n"))
        (silent (make-temp-file "lispm-kernel-silent" nil nil "#!/bin/sh\nexit 3\n")))
    (unwind-protect
        (progn
          (set-file-modes other #o755)
          (set-file-modes silent #o755)
          (should-not (lispm-kernel-program--check other))
          (should-not (lispm-kernel-program--check silent)))
      (delete-file other)
      (delete-file silent))))

(ert-deftest lispm-kernel-program-pins-what-is-published ()
  (lispm-kernel-program-test--with-sources
    (let* ((releases (expand-file-name "releases" root))
           (version (lispm-kernel-program-source-version))
           (programs (mapcar (lambda (target) (cons target (format "#!/bin/sh\n# %s\n" target)))
                             lispm-kernel-program-targets))
           (sums (lispm-kernel-program-test--release releases version programs))
           (url (concat "file://" releases)))
      (should (equal (lispm-kernel-program-published url version)
                     (sort (copy-sequence sums) (lambda (a b) (string< (car a) (car b))))))
      ;; What it writes is what is read back as pins.
      (with-temp-file (lispm-kernel-program--sums-file)
        (insert (lispm-kernel-program--render-pins version (lispm-kernel-program-published url version))))
      (dolist (target lispm-kernel-program-targets)
        (should (equal (lispm-kernel-program--pinned-sha256 target) (cdr (assoc target sums)))))
      ;; A program unlike its listing, or a target missing, is refused.
      (with-temp-file (expand-file-name (format "kernel-program-%s/lispm-kernel-x86_64-apple-darwin.gz" version)
                                        releases)
        (insert "changed"))
      (should-error (lispm-kernel-program-published url version))
      (lispm-kernel-program-test--release releases "abcdef0123456789"
                                          (list (cons "aarch64-apple-darwin" "#!/bin/sh\n")))
      (should (string-match-p "has no program for x86_64-apple-darwin"
                              (cadr (should-error (lispm-kernel-program-published url "abcdef0123456789"))))))))

(provide 'lispm-kernel-program-test)
;;; lispm-kernel-program-test.el ends here
