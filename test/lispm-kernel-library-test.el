;;; lispm-kernel-library-test.el --- Downloading, checking and building the module -*- lexical-binding: t; -*-

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
;; Each test gets a throwaway workspace of its own, made of stand-in sources
;; and a file of pins, with the module unloaded as far as these functions
;; can see.  Releases are directories read through file:// URLs and Cargo
;; is a shell script, so nothing goes over the network and no Rust is built.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lispm-kernel-library)

(defvar lispm-kernel-library-test--module nil
  "The library a test's `module-load' loaded, or nil.")

(defvar lispm-kernel-library-test--obtained nil
  "What `lispm-kernel-library-obtained-functions' were called with, newest first.")

(defconst lispm-kernel-library-test--sources
  '("Cargo.toml" "Cargo.lock"
    "crates/kernel/Cargo.toml" "crates/kernel/src/lib.rs" "crates/kernel/src/worker.rs"
    "crates/emacs-module/Cargo.toml" "crates/emacs-module/src/lib.rs")
  "The stand-in sources of a test's workspace.")

(defconst lispm-kernel-library-test--linux "liblispm_kernel_emacs-x86_64-unknown-linux-gnu.so"
  "The library published for x86_64 GNU/Linux.")

(defmacro lispm-kernel-library-test--with-sources (&rest body)
  "Run BODY in a new workspace, `root', whose sources are a minute old,
downloading as by default.  The module counts as loaded once a faked
`module-load' has loaded a file, which it does for a file holding
\"library\"."
  (declare (indent 0))
  `(let* ((root (file-name-as-directory (make-temp-file "lispm-kernel-library" t)))
          (lispm-kernel-library-source-directory root)
          (lispm-kernel-library-directory (expand-file-name "lisp/" root))
          (lispm-kernel-library-source 'download)
          (lispm-kernel-library-problem nil)
          (lispm-kernel-library--load-failure nil)
          (lispm-kernel-library--building nil)
          (lispm-kernel-library--downloading nil)
          (lispm-kernel-library-test--module nil)
          (lispm-kernel-library-test--obtained nil)
          (lispm-kernel-library-obtained-functions
           (list (lambda (loaded) (push loaded lispm-kernel-library-test--obtained))))
          (inhibit-message t)
          (featurep (symbol-function 'featurep)))
     (unwind-protect
         (cl-letf (((symbol-function 'featurep)
                    (lambda (feature &rest subfeatures)
                      (if (eq feature 'lispm-kernel-module)
                          (and lispm-kernel-library-test--module t)
                        (apply featurep feature subfeatures))))
                   ((symbol-function 'module-load)
                    (lambda (file)
                      (unless (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                                     "library")
                        (error "Not a module: %s" file))
                      (setq lispm-kernel-library-test--module file))))
           (make-directory lispm-kernel-library-directory)
           (dolist (name lispm-kernel-library-test--sources)
             (lispm-kernel-library-test--file (expand-file-name name root) name 60))
           ,@body)
       (dolist (process (list lispm-kernel-library--building lispm-kernel-library--downloading))
         (when (process-live-p process) (delete-process process)))
       (delete-directory root t))))

(defun lispm-kernel-library-test--file (file &optional contents age)
  "Write CONTENTS (by default \"library\") to FILE, AGE seconds old (by
default new), and return FILE."
  (make-directory (file-name-directory file) t)
  (write-region (or contents "library") nil file)
  (set-file-times file (time-subtract nil (or age 0)))
  file)

(defun lispm-kernel-library-test--pin (modules &optional version)
  "Pin MODULES, an alist (TARGET . CONTENTS), for VERSION, by default the
sources', as scripts/pin-module.py writes the pins."
  (write-region
   (format ";; Pins.\n(:version %S\n :modules %S)\n"
           (or version (lispm-kernel-library-source-version))
           (mapcar (lambda (module) (cons (car module) (secure-hash 'sha256 (cdr module)))) modules))
   nil (lispm-kernel-library--sums-file)))

(defun lispm-kernel-library-test--release (directory version modules)
  "Lay out the release of VERSION under DIRECTORY, MODULES being an alist
\(NAME . CONTENTS); return its URL.  Its SHA256SUMS lists what is there,
as a release that was changed lists it too."
  (let ((release (expand-file-name (concat "kernel-module-" version) directory)))
    (pcase-dolist (`(,name . ,contents) modules)
      (lispm-kernel-library-test--file (expand-file-name name release) contents))
    (write-region (mapconcat (lambda (module) (format "%s  %s\n" (secure-hash 'sha256 (cdr module)) (car module)))
                             modules "")
                  nil (expand-file-name "SHA256SUMS" release))
    (concat "file://" (directory-file-name directory))))

(defun lispm-kernel-library-test--wait ()
  "Wait, five seconds at most, for the build or download to end."
  (let ((deadline (+ (float-time) 5)))
    (while (and (or lispm-kernel-library--building lispm-kernel-library--downloading)
                (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should-not (lispm-kernel-library--busy-p))))

(defun lispm-kernel-library-test--cargo (directory script)
  "Write a stand-in cargo running SCRIPT into DIRECTORY; return DIRECTORY."
  (let ((cargo (expand-file-name "cargo" directory)))
    (lispm-kernel-library-test--file cargo (concat "#!/bin/sh\n" script "\n"))
    (set-file-modes cargo #o755)
    directory))

(ert-deftest lispm-kernel-library-target ()
  "A prebuilt module is chosen by the processor and system Emacs was built
for, and none is published for the others."
  (should (equal (lispm-kernel-library--target "aarch64-apple-darwin24.1.0") "aarch64-apple-darwin"))
  (should (equal (lispm-kernel-library--target "arm64-apple-darwin23.0.0") "aarch64-apple-darwin"))
  (should (equal (lispm-kernel-library--target "x86_64-apple-darwin21.6.0") "x86_64-apple-darwin"))
  (should (equal (lispm-kernel-library--target "x86_64-pc-linux-gnu") "x86_64-unknown-linux-gnu"))
  (should-not (lispm-kernel-library--target "aarch64-unknown-linux-gnu"))
  (should-not (lispm-kernel-library--target "x86_64-pc-linux-musl"))
  (should (equal (lispm-kernel-library--asset "aarch64-apple-darwin")
                 "liblispm_kernel_emacs-aarch64-apple-darwin.dylib"))
  (should (equal (lispm-kernel-library--asset "x86_64-unknown-linux-gnu")
                 lispm-kernel-library-test--linux)))

(ert-deftest lispm-kernel-library-source-version ()
  "The sources' version follows their contents, not their times: it is the
digest of the lines sha256sum writes for them.  What does not make the
library, tests and examples, does not count."
  (lispm-kernel-library-test--with-sources
    (let ((version (lispm-kernel-library-source-version))
          (lib (expand-file-name "crates/kernel/src/lib.rs" root)))
      (should (string-match-p "\\`[0-9a-f]\\{16\\}\\'" version))
      (should (equal (lispm-kernel-library-source-digest)
                     (secure-hash 'sha256
                                  (mapconcat (lambda (name) (format "%s  %s\n" (secure-hash 'sha256 name) name))
                                             (sort (copy-sequence lispm-kernel-library-test--sources) #'string<)
                                             ""))))
      (set-file-times lib)
      (should (equal (lispm-kernel-library-source-version) version))
      (lispm-kernel-library-test--file (expand-file-name "crates/kernel/tests/runtime.rs" root))
      (lispm-kernel-library-test--file (expand-file-name "crates/kernel/examples/mixed.rs" root))
      (lispm-kernel-library-test--file (expand-file-name "bench/fixture.rs" root))
      (lispm-kernel-library-test--pin '(("x86_64-apple-darwin" . "library")))
      (should (equal (lispm-kernel-library-source-version) version))
      (write-region "changed" nil lib)
      (should-not (equal (lispm-kernel-library-source-version) version))
      (write-region "crates/kernel/src/lib.rs" nil lib)
      (should (equal (lispm-kernel-library-source-version) version))
      ;; A new crate's files count, and so does a build script.
      (lispm-kernel-library-test--file (expand-file-name "crates/sessions/Cargo.toml" root))
      (let ((with-crate (lispm-kernel-library-source-version)))
        (should-not (equal with-crate version))
        (lispm-kernel-library-test--file (expand-file-name "crates/sessions/build.rs" root))
        (should-not (equal (lispm-kernel-library-source-version) with-crate)))))
  (let ((lispm-kernel-library-source-directory (make-temp-file "lispm-kernel-library" t)))
    (unwind-protect
        (should-not (lispm-kernel-library-source-version))
      (delete-directory lispm-kernel-library-source-directory t))))

(ert-deftest lispm-kernel-library-pins ()
  "A SHA-256 is pinned for these sources only, and for a target only when
the file names it, well formed."
  (lispm-kernel-library-test--with-sources
    (let ((system-configuration "x86_64-pc-linux-gnu"))
      (should-not (lispm-kernel-library--pinned-sha256))
      (write-region "(:version nil :modules nil)" nil (lispm-kernel-library--sums-file))
      (should-not (lispm-kernel-library--pinned-sha256))
      (write-region "(:version" nil (lispm-kernel-library--sums-file))
      (should-not (lispm-kernel-library--pinned-sha256))
      (lispm-kernel-library-test--pin '(("x86_64-unknown-linux-gnu" . "library")) "0123456789abcdef")
      (should-not (lispm-kernel-library--pinned-sha256))
      (lispm-kernel-library-test--pin '(("x86_64-unknown-linux-gnu" . "library")
                                        ("aarch64-apple-darwin" . "other")))
      (should (equal (lispm-kernel-library--pinned-sha256) (secure-hash 'sha256 "library")))
      (should (equal (lispm-kernel-library--pinned-sha256 "aarch64-apple-darwin") (secure-hash 'sha256 "other")))
      (should-not (lispm-kernel-library--pinned-sha256 "x86_64-apple-darwin"))
      (let ((system-configuration "aarch64-unknown-linux-gnu"))
        (should-not (lispm-kernel-library--pinned-sha256)))
      (write-region (format "(:version %S :modules ((\"x86_64-unknown-linux-gnu\" . \"not a checksum\")))"
                            (lispm-kernel-library-source-version))
                    nil (lispm-kernel-library--sums-file))
      (should-not (lispm-kernel-library--pinned-sha256)))))

(ert-deftest lispm-kernel-library-built-files ()
  "Cargo's libraries are found with and without a build target; one built
for another computer is not."
  (lispm-kernel-library-test--with-sources
    (let ((system-configuration "aarch64-apple-darwin24.1.0"))
      (should-not (lispm-kernel-library--built-files))
      (let ((plain (lispm-kernel-library-test--file
                    (expand-file-name "target/release/liblispm_kernel_emacs.dylib" root) nil 30))
            (targeted (lispm-kernel-library-test--file
                       (expand-file-name "target/aarch64-apple-darwin/release/liblispm_kernel_emacs.dylib" root))))
        (lispm-kernel-library-test--file
         (expand-file-name "target/x86_64-apple-darwin/release/liblispm_kernel_emacs.dylib" root))
        (lispm-kernel-library-test--file (expand-file-name "target/release/liblispm_kernel_emacs.d" root))
        (should (equal (sort (lispm-kernel-library--built-files) #'string<) (list targeted plain)))
        (should (equal (lispm-kernel-library--built-file) targeted))))))

(ert-deftest lispm-kernel-library-downloads-by-default ()
  "By default the module pinned for the sources is downloaded, Cargo there
or not, and what Cargo built is not loaded; a download is current only
while its SHA-256 is the one pinned, whatever its time."
  (lispm-kernel-library-test--with-sources
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) t)))
      (let ((system-configuration "aarch64-apple-darwin24.1.0"))
        (should-not (lispm-kernel-library--plan))
        (should (string-match-p "none is pinned" (lispm-kernel-library--why-not)))
        (lispm-kernel-library-test--pin '(("aarch64-apple-darwin" . "library")))
        (should (eq (lispm-kernel-library--plan) 'download))
        (lispm-kernel-library-test--file (expand-file-name "target/release/liblispm_kernel_emacs.dylib" root))
        (should (eq (lispm-kernel-library--plan) 'download))
        (should-not (lispm-kernel-library-file))
        (cl-letf (((symbol-function 'executable-find) (lambda (program &rest _) (not (equal program "curl")))))
          (should-not (lispm-kernel-library--plan))
          (should (string-match-p "curl" (lispm-kernel-library--why-not))))
        (let ((system-configuration "aarch64-unknown-linux-gnu"))
          (should-not (lispm-kernel-library--plan))
          (should (string-match-p "published for aarch64-unknown-linux-gnu" (lispm-kernel-library--why-not))))
        (let ((prebuilt (lispm-kernel-library-test--file (lispm-kernel-library--prebuilt-file) nil 120)))
          (should (string-prefix-p (expand-file-name "prebuilt/" root) prebuilt))
          (should (equal (lispm-kernel-library--current-file) prebuilt))
          (should (equal (lispm-kernel-library-file) prebuilt))
          (should-not (lispm-kernel-library--plan))
          ;; Sources newer than the library, as a checkout leaves them.
          (set-file-times (expand-file-name "crates/kernel/src/lib.rs" root))
          (should (equal (lispm-kernel-library-file) prebuilt))
          ;; Changed where it is kept, it is neither loaded nor current.
          (write-region "changed" nil prebuilt)
          (should-not (lispm-kernel-library-file))
          (should (eq (lispm-kernel-library--plan) 'download))
          (write-region "library" nil prebuilt)
          ;; Changed sources are no longer the ones pinned.
          (write-region "changed" nil (expand-file-name "crates/kernel/src/lib.rs" root))
          (should-not (lispm-kernel-library-file))
          (should-not (lispm-kernel-library--plan))
          (should (string-match-p "none is pinned for these sources"
                                  (lispm-kernel-library--why-not))))))))

(ert-deftest lispm-kernel-library-builds-when-asked ()
  "Asked to build, Cargo builds the module whenever its library is missing
or out of date, and nothing is downloaded, pinned or not."
  (lispm-kernel-library-test--with-sources
    (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) t)))
      (let ((system-configuration "x86_64-apple-darwin21.6.0")
            (lispm-kernel-library-source 'build))
        (lispm-kernel-library-test--pin '(("x86_64-apple-darwin" . "library")))
        (lispm-kernel-library-test--file (lispm-kernel-library--prebuilt-file))
        (should (eq (lispm-kernel-library--plan) 'build))
        (should-not (lispm-kernel-library-file))
        (let ((built (lispm-kernel-library-test--file
                      (expand-file-name "target/x86_64-apple-darwin/release/liblispm_kernel_emacs.dylib" root)
                      nil 30)))
          (should-not (lispm-kernel-library--plan))
          (should (equal (lispm-kernel-library-file) built))
          (set-file-times (expand-file-name "Cargo.lock" root))
          (should (eq (lispm-kernel-library--plan) 'build))
          ;; Out of date, it is what there is until Cargo has built anew.
          (should (equal (lispm-kernel-library-file) built)))
        (cl-letf (((symbol-function 'executable-find) #'ignore))
          (should-not (lispm-kernel-library--plan))
          (should (string-match-p "Cargo" (lispm-kernel-library--why-not))))))))

(ert-deftest lispm-kernel-library-bundle ()
  "A bundle, Lisp files and library with no sources, loads its library and
builds or downloads nothing."
  (let* ((root (file-name-as-directory (make-temp-file "lispm-kernel-library" t)))
         (bundle (expand-file-name "kernel-module-0.1.0/" root))
         (lispm-kernel-library-directory bundle)
         (lispm-kernel-library-source-directory root)
         (lispm-kernel-library-source 'download)
         (system-configuration "x86_64-pc-linux-gnu"))
    (make-directory bundle)
    (unwind-protect
        (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) t)))
          (should-not (lispm-kernel-library-file))
          (should (string-match-p "sources" (lispm-kernel-library--why-not)))
          (let ((library (lispm-kernel-library-test--file
                          (expand-file-name lispm-kernel-library-test--linux bundle))))
            (should-not (lispm-kernel-library--prebuilt-file))
            (should-not (lispm-kernel-library--plan))
            (should (equal (lispm-kernel-library-file) library))))
      (delete-directory root t))))

(ert-deftest lispm-kernel-library-install-prebuilt ()
  "A downloaded library is kept only when its SHA-256 is the one pinned,
and then replaces those kept for other versions."
  (lispm-kernel-library-test--with-sources
    (let* ((system-configuration "x86_64-pc-linux-gnu")
           (library (lispm-kernel-library-test--file (expand-file-name "download/lib.so" root) "the library"))
           (file (lispm-kernel-library--prebuilt-file))
           (old (lispm-kernel-library-test--file
                 (expand-file-name (concat "0123456789abcdef/" lispm-kernel-library-test--linux)
                                   (lispm-kernel-library--prebuilt-directory)))))
      (should-error (lispm-kernel-library--install-prebuilt library (make-string 64 ?0) file))
      (should-not (file-exists-p file))
      (should (file-exists-p old))
      (should (equal (lispm-kernel-library--install-prebuilt library (secure-hash 'sha256 "the library") file)
                     file))
      (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string)) "the library"))
      (should-not (file-exists-p (concat file ".part")))
      (should-not (file-exists-p (file-name-directory old))))))

(ert-deftest lispm-kernel-library-download ()
  "Getting the module downloads the library pinned for the sources in the
background, checks it and loads it; Cargo, though there, builds nothing."
  (skip-unless (executable-find "curl"))
  (lispm-kernel-library-test--with-sources
    (let* ((system-configuration "x86_64-pc-linux-gnu")
           (lispm-kernel-library-prebuilt-url
            (lispm-kernel-library-test--release (expand-file-name "releases" root)
                                                (lispm-kernel-library-source-version)
                                                `((,lispm-kernel-library-test--linux . "library")
                                                  ("liblispm_kernel_emacs-aarch64-apple-darwin.dylib" . "other"))))
           (exec-path (cons (lispm-kernel-library-test--cargo (expand-file-name "bin" root) "touch built")
                            exec-path)))
      (lispm-kernel-library-test--pin '(("x86_64-unknown-linux-gnu" . "library")))
      (should (eq (lispm-kernel-library-obtain) 'pending))
      (should (eq (lispm-kernel-library-obtain) 'pending))
      (should-not lispm-kernel-library-test--module)
      (lispm-kernel-library-test--wait)
      (should (equal lispm-kernel-library-test--obtained '(t)))
      (should (equal lispm-kernel-library-test--module (lispm-kernel-library--prebuilt-file)))
      (should (string-suffix-p lispm-kernel-library-test--linux lispm-kernel-library-test--module))
      (should-not lispm-kernel-library-problem)
      (should-not (file-exists-p (expand-file-name "built" root)))
      (should (eq (lispm-kernel-library-obtain) 'loaded)))))

(ert-deftest lispm-kernel-library-download-refused ()
  "A library changed on the release is refused though the release's own
SHA256SUMS vouches for it, as is a release not published; those waiting
hear that the module is not there, and why."
  (skip-unless (executable-find "curl"))
  (lispm-kernel-library-test--with-sources
    (let* ((system-configuration "x86_64-pc-linux-gnu")
           (releases (expand-file-name "releases" root))
           (lispm-kernel-library-prebuilt-url
            (lispm-kernel-library-test--release releases (lispm-kernel-library-source-version)
                                                `((,lispm-kernel-library-test--linux . "tampered")))))
      (lispm-kernel-library-test--pin '(("x86_64-unknown-linux-gnu" . "library")))
      (should (eq (lispm-kernel-library-obtain) 'pending))
      (lispm-kernel-library-test--wait)
      (should (equal lispm-kernel-library-test--obtained '(nil)))
      (should-not lispm-kernel-library-test--module)
      (should-not (file-exists-p (lispm-kernel-library--prebuilt-file)))
      (should (string-match-p "SHA-256 differs, so it was refused" lispm-kernel-library-problem))
      ;; Sources whose release nobody published, pinned all the same.
      (write-region "unpublished" nil (expand-file-name "crates/kernel/src/lib.rs" root))
      (lispm-kernel-library-test--pin '(("x86_64-unknown-linux-gnu" . "library")))
      (should (eq (lispm-kernel-library-obtain) 'pending))
      (lispm-kernel-library-test--wait)
      (should (equal lispm-kernel-library-test--obtained '(nil nil)))
      (should-not (file-exists-p (lispm-kernel-library--prebuilt-file)))
      (should (string-match-p "could not be downloaded from file:" lispm-kernel-library-problem)))))

(ert-deftest lispm-kernel-library-unpinned ()
  "Without a SHA-256 pinned for the sources nothing is downloaded, and the
problem says so."
  (lispm-kernel-library-test--with-sources
    (let ((system-configuration "x86_64-pc-linux-gnu"))
      (lispm-kernel-library-test--pin '(("x86_64-unknown-linux-gnu" . "library")) "0123456789abcdef")
      (should-not (lispm-kernel-library-obtain))
      (should-not lispm-kernel-library--downloading)
      (should (string-match-p "none is pinned for these sources" lispm-kernel-library-problem))
      (should-error (lispm-kernel-library-download) :type 'user-error))))

(ert-deftest lispm-kernel-library-build ()
  "Asked to build, getting the module builds it in the background and
loads what Cargo built."
  (lispm-kernel-library-test--with-sources
    (let ((lispm-kernel-library-source 'build)
          (exec-path (cons (lispm-kernel-library-test--cargo
                            (expand-file-name "bin" root)
                            "mkdir -p target/release && printf library > target/release/liblispm_kernel_emacs.so")
                           exec-path)))
      (should (eq (lispm-kernel-library-obtain) 'pending))
      (lispm-kernel-library-test--wait)
      (should (equal lispm-kernel-library-test--obtained '(t)))
      (should (equal lispm-kernel-library-test--module
                     (expand-file-name "target/release/liblispm_kernel_emacs.so" root)))
      (should-not (lispm-kernel-library--stale-p)))))

(ert-deftest lispm-kernel-library-build-fails ()
  "A build asked for that fails, as with a Rust too old, says so and
downloads nothing in its place."
  (skip-unless (executable-find "curl"))
  (lispm-kernel-library-test--with-sources
    (let* ((system-configuration "x86_64-pc-linux-gnu")
           (lispm-kernel-library-source 'build)
           (exec-path (cons (lispm-kernel-library-test--cargo (expand-file-name "bin" root) "exit 101")
                            exec-path))
           (lispm-kernel-library-prebuilt-url
            (lispm-kernel-library-test--release (expand-file-name "releases" root)
                                                (lispm-kernel-library-source-version)
                                                `((,lispm-kernel-library-test--linux . "library")))))
      (lispm-kernel-library-test--pin '(("x86_64-unknown-linux-gnu" . "library")))
      (should (eq (lispm-kernel-library-obtain) 'pending))
      (lispm-kernel-library-test--wait)
      (should (equal lispm-kernel-library-test--obtained '(nil)))
      (should (string-match-p "Cargo could not build it" lispm-kernel-library-problem))
      (should-not (file-exists-p (lispm-kernel-library--prebuilt-file))))))

(ert-deftest lispm-kernel-library-load-failure ()
  "A library that does not load is not tried again, and the problem says
why; nothing loads while the module is being downloaded."
  (lispm-kernel-library-test--with-sources
    (cl-letf (((symbol-function 'executable-find) #'ignore))
      (let ((system-configuration "aarch64-apple-darwin24.1.0"))
        (lispm-kernel-library-test--pin '(("aarch64-apple-darwin" . "not a module")))
        (let ((library (lispm-kernel-library-test--file (lispm-kernel-library--prebuilt-file) "not a module")))
          (let ((lispm-kernel-library--downloading (make-process :name "lispm-kernel-test" :command '("sleep" "5"))))
            (unwind-protect
                (progn
                  (should (eq (lispm-kernel-library-obtain) 'pending))
                  (should-not (lispm-kernel-library-load)))
              (delete-process lispm-kernel-library--downloading)))
          (should-not (lispm-kernel-library-obtain))
          (should (equal (car lispm-kernel-library--load-failure) library))
          (should (string-match-p "does not load: Not a module" lispm-kernel-library-problem))
          (should-not (lispm-kernel-library-obtain))
          (should (string-match-p "does not load" lispm-kernel-library-problem))
          (setq lispm-kernel-library--load-failure nil)
          (lispm-kernel-library-test--pin '(("aarch64-apple-darwin" . "library")))
          (write-region "library" nil library)
          (should (eq (lispm-kernel-library-obtain) 'loaded))
          (should-not lispm-kernel-library-problem))))))

(ert-deftest lispm-kernel-library-batch-download ()
  "An installer's batch Emacs downloads the module pinned, and exits with 1
when what it got does not load as a module."
  (skip-unless (and (executable-find "curl") (lispm-kernel-library--target)))
  (lispm-kernel-library-test--with-sources
    (let* ((target (lispm-kernel-library--target))
           (url (lispm-kernel-library-test--release (expand-file-name "releases" root)
                                                    (lispm-kernel-library-source-version)
                                                    `((,(lispm-kernel-library--asset target) . "library"))))
           (status
            (progn
              (lispm-kernel-library-test--pin `((,target . "library")))
              (call-process (expand-file-name invocation-name invocation-directory) nil nil nil
                            "-Q" "--batch" "-L" (file-name-directory (locate-library "lispm-kernel-library"))
                            "-l" "lispm-kernel-library"
                            "--eval" (format "(setq lispm-kernel-library-source-directory %S
                                                    lispm-kernel-library-directory %S
                                                    lispm-kernel-library-prebuilt-url %S)"
                                             root lispm-kernel-library-directory url)
                            "-f" "lispm-kernel-library-batch-download"))))
      (should (= status 1))
      (should (file-exists-p (lispm-kernel-library--prebuilt-file))))))

(provide 'lispm-kernel-library-test)
;;; lispm-kernel-library-test.el ends here
