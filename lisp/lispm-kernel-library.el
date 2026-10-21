;;; lispm-kernel-library.el --- The kernel's module, downloaded and checked -*- lexical-binding: t; -*-

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
;; The kernel runs in a dynamic module, the workspace's lispm-kernel-emacs
;; crate, and nobody has to build it or say where it is.  The library the
;; repository's kernel-module workflow built for this computer from these
;; sources is downloaded (`lispm-kernel-library-download'), and kept and
;; loaded only when its SHA-256 is the one pinned beside this file, in
;; lispm-kernel-module-sums.eld.  Those checksums come with the Lisp, from
;; the repository's signed history, not from the release, so a library
;; changed on the release after it was pinned is refused.
;;
;; Cargo builds the module only when asked to: `lispm-kernel-library-source'
;; set to `build' builds it from the sources there are
;; (`lispm-kernel-library-build'), and again when one is newer than the
;; library Cargo built, and downloads nothing.  Either runs in the
;; background: `lispm-kernel-library-obtain' answers at once,
;; `lispm-kernel-library-obtained-functions' hears when the module is
;; there, and `lispm-kernel-library-problem' says why it is not.
;;
;;   download   prebuilt/VERSION/liblispm_kernel_emacs-TRIPLE.*   the default
;;   build      target/[TRIPLE/]release/liblispm_kernel_emacs.*    Cargo's
;;   bundle     liblispm_kernel_emacs-TRIPLE.* beside this file, as
;;              scripts/package-module.py lays one out
;;
;; VERSION is `lispm-kernel-library-source-version', a digest of the Rust
;; sources.  The workflow publishes the libraries of each version as the
;; release kernel-module-VERSION; scripts/pin-module.py then writes their
;; SHA-256 into lispm-kernel-module-sums.eld, in a commit of its own, the
;; release of the kernel that ships them.
;;; Code:
(require 'seq)
(require 'subr-x)
(require 'lispm-kernel)
(declare-function lispm-kernel-module-protocol-version "ext:lispm-kernel-module" ())

(defcustom lispm-kernel-library-source 'download
  "Where the kernel's module comes from.
`download', the default, downloads the library the repository's workflow
built for this computer from these sources, and keeps and loads it only
when its SHA-256 is the one pinned in lispm-kernel-module-sums.eld.
`build' builds it with Rust's Cargo instead, from the sources there are,
and again when one is newer than the library Cargo built; nothing is
downloaded then."
  :type '(choice (const :tag "Download it, checked" download)
                 (const :tag "Build it with Cargo" build))
  :group 'lispm-kernel)

(defcustom lispm-kernel-library-prebuilt-url
  "https://github.com/LispMachineLab/lispm-kernel/releases/download"
  "Where the prebuilt modules are.
The modules of the sources whose version is VERSION, see
`lispm-kernel-library-source-version', are under kernel-module-VERSION
there: liblispm_kernel_emacs-TARGET.dylib or .so for each Rust TARGET.
Whatever the URL, a library is kept only when its SHA-256 is the one
lispm-kernel-module-sums.eld pins."
  :type 'string :group 'lispm-kernel)

(defvar lispm-kernel-library-obtained-functions nil
  "Functions called when a build or download in the background ends.
Each gets one argument, non-nil when the module is then loaded.")

(defvar lispm-kernel-library-problem nil
  "Why the module could not be had, a sentence, or nil.")

(defconst lispm-kernel-library-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of the kernel's Lisp files, where a bundle keeps its library.")

(defconst lispm-kernel-library-source-directory
  (file-name-directory (directory-file-name lispm-kernel-library-directory))
  "Root of the Cargo workspace whose crates make the module.")

(defvar lispm-kernel-library--building nil
  "The Cargo process building the module, until its sentinel has run.")

(defvar lispm-kernel-library--downloading nil
  "The curl process downloading the module, until its sentinel has run.")

(defvar lispm-kernel-library--load-failure nil
  "The library that did not load, and why: (FILE . ERROR).
It is not tried again in this session.")

;;;; Sources and their version

(defun lispm-kernel-library--source-files ()
  "Return the module's sources, sorted: the workspace's manifest and lock
file, and each crate's manifest, build script and Rust files under src."
  (let ((root lispm-kernel-library-source-directory))
    (sort (seq-filter
           #'file-regular-p
           (append (mapcar (lambda (name) (expand-file-name name root)) '("Cargo.toml" "Cargo.lock"))
                   (mapcan (lambda (crate)
                             (let ((crate (file-name-directory crate)))
                               (append (mapcar (lambda (name) (expand-file-name name crate))
                                               '("Cargo.toml" "build.rs"))
                                       (when (file-directory-p (expand-file-name "src" crate))
                                         (directory-files-recursively
                                          (expand-file-name "src" crate) "\\.rs\\'")))))
                           (file-expand-wildcards (expand-file-name "crates/*/Cargo.toml" root)))))
          #'string<)))

(defun lispm-kernel-library--sha256 (file)
  "Return the SHA-256 of FILE's bytes, in hex."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun lispm-kernel-library-source-digest ()
  "Return the SHA-256 of the module's sources, in hex, or nil without them.
It is that of what sha256sum writes for them at the workspace's root: for
each, in order, a line of its SHA-256, two spaces and its name."
  (when-let* ((files (lispm-kernel-library--source-files)))
    (secure-hash 'sha256
                 (mapconcat (lambda (file)
                              (format "%s  %s\n" (lispm-kernel-library--sha256 file)
                                      (file-relative-name file lispm-kernel-library-source-directory)))
                            files ""))))

(defun lispm-kernel-library-source-version ()
  "Return the version of the module's sources, or nil without them: the
first 16 digits of `lispm-kernel-library-source-digest'.  A prebuilt
module is published, pinned and kept under it, so a library downloaded
for the sources stays current for them whatever its time, and none is
once they change."
  (when-let* ((digest (lispm-kernel-library-source-digest)))
    (substring digest 0 16)))

;;;; Pinned checksums

(defun lispm-kernel-library--sums-file ()
  "Return the file pinning the SHA-256 of the libraries to download."
  (expand-file-name "lispm-kernel-module-sums.eld" lispm-kernel-library-directory))

(defun lispm-kernel-library--pins ()
  "Return what lispm-kernel-module-sums.eld pins: a plist whose :version
is the version of the sources pinned, and :modules an alist of a SHA-256
for each Rust target; nil when nothing is pinned."
  (let ((file (lispm-kernel-library--sums-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((pins (ignore-errors (read (current-buffer)))))
          (and (listp pins) pins))))))

(defun lispm-kernel-library--pinned-sha256 (&optional target)
  "Return the SHA-256 pinned for the library of these sources for TARGET,
by default this Emacs's, or nil when none is pinned for them."
  (when-let* ((target (or target (lispm-kernel-library--target)))
              (version (lispm-kernel-library-source-version))
              (pins (lispm-kernel-library--pins))
              ((equal (plist-get pins :version) version))
              (sha256 (cdr (assoc target (plist-get pins :modules)))))
    (and (stringp sha256) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256) sha256)))

;;;; Libraries

(defun lispm-kernel-library--target (&optional configuration)
  "Return the Rust target of the prebuilt module for an Emacs built for
CONFIGURATION, by default this one's `system-configuration', or nil when
none is published for it."
  (let ((configuration (or configuration system-configuration)))
    (cond ((string-match-p "\\`\\(?:aarch64\\|arm64\\)-apple-darwin" configuration) "aarch64-apple-darwin")
          ((string-match-p "\\`x86_64-apple-darwin" configuration) "x86_64-apple-darwin")
          ((string-match-p "\\`x86_64-[^-]+-linux-gnu\\'" configuration) "x86_64-unknown-linux-gnu"))))

(defun lispm-kernel-library--asset (target)
  "Return the name the library for Rust TARGET is published under."
  (format "liblispm_kernel_emacs-%s.%s" target (if (string-suffix-p "-darwin" target) "dylib" "so")))

(defun lispm-kernel-library--built-files ()
  "Return every library of the module Cargo built for this computer.
Cargo puts it under target/release, or target/TRIPLE/release when a build
target is set; a library built for another computer's TRIPLE is left out."
  (let ((root lispm-kernel-library-source-directory))
    (seq-filter (lambda (file) (member (file-name-extension file) '("dylib" "so")))
                (mapcan (lambda (directory)
                          (file-expand-wildcards
                           (expand-file-name (concat directory "/liblispm_kernel_emacs.*") root)))
                        (list "target/release"
                              (format "target/%s/release" (or (lispm-kernel-library--target) "*")))))))

(defun lispm-kernel-library--built-file ()
  "Return the newest library of the module Cargo built, or nil."
  (car (sort (lispm-kernel-library--built-files) #'file-newer-than-file-p)))

(defun lispm-kernel-library--stale-p ()
  "Return non-nil when a source of the module is newer than the library
Cargo built, as after an update."
  (when-let* ((library (lispm-kernel-library--built-file)))
    (seq-some (lambda (file) (file-newer-than-file-p file library))
              (lispm-kernel-library--source-files))))

(defun lispm-kernel-library--prebuilt-directory ()
  "Return the directory downloaded libraries are kept in, by version."
  (expand-file-name "prebuilt" lispm-kernel-library-source-directory))

(defun lispm-kernel-library--prebuilt-file ()
  "Return where the library downloaded for the sources is kept, whether it
is there or not, or nil when none is published for this Emacs or there
are no sources to name its version."
  (when-let* ((target (lispm-kernel-library--target))
              (version (lispm-kernel-library-source-version)))
    (expand-file-name (lispm-kernel-library--asset target)
                      (expand-file-name version (lispm-kernel-library--prebuilt-directory)))))

(defun lispm-kernel-library--checked-p (file)
  "Return non-nil when FILE is there and its SHA-256 is the one pinned."
  (when-let* ((pinned (lispm-kernel-library--pinned-sha256)))
    (and (file-exists-p file) (equal (lispm-kernel-library--sha256 file) pinned))))

(defun lispm-kernel-library--bundled-file ()
  "Return the library a bundle keeps beside the Lisp files, or nil."
  (when-let* ((target (lispm-kernel-library--target))
              (file (expand-file-name (lispm-kernel-library--asset target)
                                      lispm-kernel-library-directory)))
    (and (file-exists-p file) file)))

(defun lispm-kernel-library--building-p ()
  "Return non-nil when the module is to be built, not downloaded."
  (eq lispm-kernel-library-source 'build))

(defun lispm-kernel-library--current-file ()
  "Return a library of the module current for its sources, or nil: when
building, the one Cargo built unless a source is newer; else the one
downloaded for them, when its SHA-256 is the one pinned; failing that, a
bundle's."
  (or (if (lispm-kernel-library--building-p)
          (let ((built (lispm-kernel-library--built-file)))
            (and built (not (lispm-kernel-library--stale-p)) built))
        (let ((prebuilt (lispm-kernel-library--prebuilt-file)))
          (and prebuilt (lispm-kernel-library--checked-p prebuilt) prebuilt)))
      (lispm-kernel-library--bundled-file)))

(defun lispm-kernel-library-file ()
  "Return the library of the module to load, or nil: a current one, see
`lispm-kernel-library--current-file', else, when building, the newest
one Cargo built, out of date.  A download is never loaded unchecked."
  (or (lispm-kernel-library--current-file)
      (and (lispm-kernel-library--building-p) (lispm-kernel-library--built-file))))

(defun lispm-kernel-library--plan ()
  "Return how to get the module: `build' when building is asked for,
Cargo and the sources are there, and the library Cargo built is missing
or older than a source; `download' otherwise, when no library checked
for these sources is there and one is pinned for this Emacs; else nil."
  (if (lispm-kernel-library--building-p)
      (and (executable-find "cargo")
           (lispm-kernel-library--source-files)
           (or (null (lispm-kernel-library--built-file)) (lispm-kernel-library--stale-p))
           'build)
    (and (lispm-kernel-library--prebuilt-file)
         (not (lispm-kernel-library--current-file))
         (lispm-kernel-library--pinned-sha256)
         (executable-find "curl")
         'download)))

(defun lispm-kernel-library--why-not ()
  "Return why no module can be had, a sentence."
  (let ((version (lispm-kernel-library-source-version)))
    (cond ((lispm-kernel-library--building-p)
           (cond ((not version) "the kernel's sources, to build it from, are not there")
                 ((not (executable-find "cargo")) "building it needs Rust's Cargo")
                 (t "Cargo built no library of it: see *lispm-kernel build*")))
          ((not (lispm-kernel-library--target))
           (format "none is published for %s" system-configuration))
          ((not version) "the kernel's sources, which name the module to download, are not there")
          ((not (lispm-kernel-library--pinned-sha256))
           (format "none is pinned for these sources (version %s); set `lispm-kernel-library-source' to `build' to build one"
                   version))
          ((not (executable-find "curl")) "downloading it needs curl")
          (t "none is there"))))

(defun lispm-kernel-library--busy-p ()
  "Return non-nil while the module is being built or downloaded.
That lasts until the process's sentinel has run, not only while it runs."
  (and (or lispm-kernel-library--building lispm-kernel-library--downloading) t))

(defun lispm-kernel-library-load ()
  "Load the module when a library of it is there; return non-nil once it
is loaded.  Nothing is loaded while it is being built or downloaded, nor
a library that did not load before."
  (or (featurep 'lispm-kernel-module)
      (when-let* (((fboundp 'module-load))
                  ((not (lispm-kernel-library--busy-p)))
                  (file (lispm-kernel-library-file))
                  ((not (equal file (car lispm-kernel-library--load-failure)))))
        (condition-case error
            (module-load file)
          (error
           (setq lispm-kernel-library--load-failure (cons file error)
                 lispm-kernel-library-problem (format "%s does not load: %s" file (error-message-string error)))
           (message "lispm-kernel's module does not load: %s" (error-message-string error))))
        (featurep 'lispm-kernel-module))))

(defun lispm-kernel-library--finish (what)
  "Load the module, which was WHAT, a word such as \"downloaded\", or nil
when it could not be got, and tell `lispm-kernel-library-obtained-functions'."
  (let ((loaded (featurep 'lispm-kernel-module)))
    (cond ((and loaded what)
           (message "lispm-kernel's module is %s: restart Emacs to use it" what))
          (loaded)
          ((setq loaded (lispm-kernel-library-load))
           (when what (message "lispm-kernel's module is %s" what))))
    (when loaded (setq lispm-kernel-library-problem nil))
    (run-hook-with-args 'lispm-kernel-library-obtained-functions loaded)))

;;;; Building with Cargo, when asked to

(defun lispm-kernel-library-build ()
  "Build the module with Cargo in the background, then load it.
Its output is in the *lispm-kernel build* buffer.  This is how the module
is got when `lispm-kernel-library-source' is `build'."
  (interactive)
  (unless (and (executable-find "cargo") (lispm-kernel-library--source-files))
    (user-error "Building lispm-kernel's module needs Rust's Cargo and the kernel's sources"))
  (unless lispm-kernel-library--building
    (let ((default-directory (file-name-as-directory lispm-kernel-library-source-directory))
          (buffer (get-buffer-create "*lispm-kernel build*")))
      (with-current-buffer buffer (erase-buffer))
      (message "Building lispm-kernel's module…")
      (setq lispm-kernel-library--building
            (make-process
             :name "lispm-kernel build" :buffer buffer :noquery t
             :command '("cargo" "build" "--release" "--locked" "-p" "lispm-kernel-emacs")
             :sentinel
             (lambda (process _event)
               (unless (process-live-p process)
                 (setq lispm-kernel-library--building nil)
                 (if (and (= (process-exit-status process) 0) (lispm-kernel-library--built-file))
                     (progn
                       ;; Cargo leaves a library it found current untouched.
                       (set-file-times (lispm-kernel-library--built-file))
                       (lispm-kernel-library--finish "built"))
                   (setq lispm-kernel-library-problem "Cargo could not build it: see *lispm-kernel build*")
                   (message "lispm-kernel's module could not be built: see %s" "*lispm-kernel build*")
                   (lispm-kernel-library--finish nil)))))))))

;;;; Downloading, checked

(defun lispm-kernel-library--install-prebuilt (library sha256 file)
  "Keep the downloaded LIBRARY as FILE when its SHA-256 is SHA256, the one
pinned, and remove the libraries kept for other versions; return FILE.
Signal an error when it is not."
  (let ((name (file-name-nondirectory file))
        (directory (directory-file-name (file-name-directory file))))
    (unless (file-exists-p library)
      (error "The download is incomplete"))
    (unless (equal (lispm-kernel-library--sha256 library) sha256)
      (error "%s is not the library pinned for these sources: its SHA-256 differs, so it was refused" name))
    (make-directory directory t)
    ;; Renamed into place, so the library is there whole or not at all.
    (copy-file library (concat file ".part") t)
    (rename-file (concat file ".part") file t)
    (dolist (old (directory-files (lispm-kernel-library--prebuilt-directory) t "\\`[^.]"))
      (when (and (file-directory-p old) (not (string= old directory)))
        (delete-directory old t)))
    file))

(defun lispm-kernel-library-download ()
  "Download the module built for this computer from the sources there are,
in the background, check it against the SHA-256 pinned for it, then load
it.  It comes from `lispm-kernel-library-prebuilt-url'; what went wrong,
if anything, is in `lispm-kernel-library-problem' and the
*lispm-kernel download* buffer."
  (interactive)
  (let ((file (lispm-kernel-library--prebuilt-file))
        (sha256 (lispm-kernel-library--pinned-sha256)))
    (unless (and file sha256 (executable-find "curl"))
      (user-error "No lispm-kernel module can be downloaded: %s" (lispm-kernel-library--why-not)))
    (unless lispm-kernel-library--downloading
      (let* ((name (file-name-nondirectory file))
             (url (format "%s/kernel-module-%s/%s" (string-trim-right lispm-kernel-library-prebuilt-url "/+")
                          (lispm-kernel-library-source-version) name))
             (directory (make-temp-file "lispm-kernel" t))
             (library (expand-file-name name directory))
             (buffer (get-buffer-create "*lispm-kernel download*")))
        (with-current-buffer buffer (erase-buffer))
        (message "Downloading lispm-kernel's module…")
        (setq lispm-kernel-library--downloading
              (make-process
               :name "lispm-kernel download" :buffer buffer :noquery t
               :command (list "curl" "--fail" "--silent" "--show-error" "--location" "--retry" "2"
                              "--output" library url)
               :sentinel
               (lambda (process _event)
                 (unless (process-live-p process)
                   (setq lispm-kernel-library--downloading nil)
                   (let* ((problem nil)
                          (installed
                           (if (/= (process-exit-status process) 0)
                               (progn
                                 (setq problem (format "it could not be downloaded from %s: %s" url
                                                       (if (buffer-live-p buffer)
                                                           (with-current-buffer buffer
                                                             (string-trim (buffer-string)))
                                                         "")))
                                 nil)
                             (condition-case error
                                 (lispm-kernel-library--install-prebuilt library sha256 file)
                               (error
                                (setq problem (error-message-string error))
                                (when (buffer-live-p buffer)
                                  (with-current-buffer buffer (insert problem "\n")))
                                nil)))))
                     (delete-directory directory t)
                     (when problem
                       (setq lispm-kernel-library-problem problem)
                       (message "lispm-kernel's module: %s" problem))
                     (lispm-kernel-library--finish (and installed "downloaded")))))))))))

(defun lispm-kernel-library-batch-download ()
  "Download the module, unless a library checked for its sources is there,
for an installer or a workflow running Emacs in batch: Emacs then exits
with 0 once the module loads and speaks this Lisp's protocol, else 1,
having said what went wrong."
  (unless (lispm-kernel-library--current-file)
    (if (not (lispm-kernel-library--plan))
        (message "No lispm-kernel module can be downloaded: %s" (lispm-kernel-library--why-not))
      (lispm-kernel-library-download)
      (while lispm-kernel-library--downloading
        (accept-process-output nil 0.1))))
  (kill-emacs (if (and (lispm-kernel-library-load)
                       (eql (lispm-kernel-module-protocol-version) lispm-kernel-protocol-version))
                  0 1)))

;;;; Getting it

(defun lispm-kernel-library-obtain ()
  "Get the module loaded without blocking Emacs, and say how it went.
Return `loaded' when it is loaded now; `pending' while it is downloaded,
or built, in the background, see `lispm-kernel-library--plan', the
functions of `lispm-kernel-library-obtained-functions' being called once
that ends; nil when there is none and none can be had, and
`lispm-kernel-library-problem' then says why."
  (cond ((featurep 'lispm-kernel-module) 'loaded)
        ((lispm-kernel-library--busy-p) 'pending)
        ((pcase (lispm-kernel-library--plan)
           ('build (lispm-kernel-library-build) t)
           ('download (lispm-kernel-library-download) t))
         'pending)
        ((lispm-kernel-library-load) (setq lispm-kernel-library-problem nil) 'loaded)
        (t (let ((file (lispm-kernel-library-file)))
             (unless (and file (equal file (car lispm-kernel-library--load-failure)))
               (setq lispm-kernel-library-problem (lispm-kernel-library--why-not))))
           nil)))

(provide 'lispm-kernel-library)
;;; lispm-kernel-library.el ends here
