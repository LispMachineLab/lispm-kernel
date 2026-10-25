;;; lispm-kernel-program.el --- The kernel program, downloaded and checked -*- lexical-binding: t; -*-

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

;; The kernel is one executable, SBCL's runtime and the kernel's core,
;; and nobody has to build it or say where it is.  The one the
;; repository's kernel-program workflow built for this computer from
;; these sources is downloaded (`lispm-kernel-program-download'), and
;; kept only when its SHA-256 is the one pinned beside this file, in
;; lispm-kernel-program-sums.eld.  Those checksums come with the Lisp,
;; from the repository's signed history, not from the release, so a
;; program changed on the release after it was pinned is refused.
;;
;; SBCL builds it only when asked to: `lispm-kernel-program-source' set
;; to `build' builds it from the sources there are
;; (`lispm-kernel-program-build'), and again when one is newer than the
;; program SBCL built, and downloads nothing.  Either runs in the
;; background: `lispm-kernel-program-obtain' answers at once,
;; `lispm-kernel-program-obtained-functions' hears when the program is
;; there, and `lispm-kernel-program-problem' says why it is not.
;; `lispm-kernel-program-progress-functions' hear how far a download
;; is, for an installer's window, and `lispm-kernel-program-stop' stops
;; either.
;;
;;   download   prebuilt/VERSION/lispm-kernel-TARGET   the default
;;   build      build/lispm-kernel                     SBCL's
;;
;; VERSION is `lispm-kernel-program-source-version', a digest of the
;; kernel's sources.  The workflow publishes the programs of each version,
;; compressed with gzip, as the release kernel-program-VERSION;
;; `lispm-kernel-program-batch-pin' then writes the SHA-256 of each into
;; lispm-kernel-program-sums.eld, in a commit of its own, the release of
;; the kernel that ships them.

;;; Code:

(require 'seq)
(require 'subr-x)
(require 'lispm-kernel)

(defcustom lispm-kernel-program-source 'download
  "Where the kernel program comes from.
`download', the default, downloads the program the repository's workflow
built for this computer from these sources, and keeps it only when its
SHA-256 is the one pinned in lispm-kernel-program-sums.eld.  `build'
builds it with SBCL instead, from the sources there are, and again when
one is newer than the program SBCL built; nothing is downloaded then."
  :type '(choice (const :tag "Download it, checked" download)
                 (const :tag "Build it with SBCL" build))
  :group 'lispm-kernel)

(defcustom lispm-kernel-program-prebuilt-url
  "https://github.com/LispMachineLab/lispm-kernel/releases/download"
  "Where the prebuilt programs are.
The programs of the sources whose version is VERSION, see
`lispm-kernel-program-source-version', are under kernel-program-VERSION
there: lispm-kernel-TARGET.gz for each TARGET.  Whatever the URL, a
program is kept only when its SHA-256 is the one
lispm-kernel-program-sums.eld pins."
  :type 'string :group 'lispm-kernel)

(defvar lispm-kernel-program-obtained-functions nil
  "Functions called when a build or download in the background ends.
Each gets one argument, non-nil when the program is then there.")

(defvar lispm-kernel-program-problem nil
  "Why the program could not be had, a sentence, or nil.")

(defvar lispm-kernel-program-progress-functions nil
  "Functions called as the program downloads, each with how much of it
is there, a fraction from 0 to 1, as curl counts it.")

(defvar lispm-kernel-program-progress nil
  "How much of the program downloading is there, a fraction from 0 to 1,
or nil while curl has not said, and when nothing downloads.")

(defconst lispm-kernel-program-lisp-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of the kernel's Emacs Lisp.")

(defconst lispm-kernel-program-source-directory
  (file-name-directory (directory-file-name lispm-kernel-program-lisp-directory))
  "Root of the kernel's repository, whose Common Lisp makes the program.")

(defconst lispm-kernel-program-targets
  '("aarch64-apple-darwin" "x86_64-apple-darwin" "x86_64-unknown-linux-gnu")
  "The computers a program is published for.")

(defvar lispm-kernel-program--building nil
  "The SBCL process building the program, until its sentinel has run.")

(defvar lispm-kernel-program--downloading nil
  "The process downloading or unpacking the program, until its sentinel has run.")

(defvar lispm-kernel-program--stopped nil
  "Non-nil once `lispm-kernel-program-stop' stopped the build or download
under way, until its sentinel has run.")

;;;; Sources and their version

(defun lispm-kernel-program--source-files ()
  "Return the program's sources, sorted: its system definition, its build
script and the Common Lisp under src."
  (let ((root lispm-kernel-program-source-directory))
    (sort (seq-filter
           #'file-regular-p
           (append (mapcar (lambda (name) (expand-file-name name root))
                           '("lispm-kernel.asd" "scripts/build.lisp"))
                   (and (file-directory-p (expand-file-name "src" root))
                        (directory-files-recursively (expand-file-name "src" root) "\\.lisp\\'"))))
          #'string<)))

(defun lispm-kernel-program--sha256 (file)
  "Return the SHA-256 of FILE's bytes, in hex."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(defun lispm-kernel-program-source-digest ()
  "Return the SHA-256 of the program's sources, in hex, or nil without them.
It is that of what sha256sum writes for them at the repository's root:
for each, in order, a line of its SHA-256, two spaces and its name."
  (when-let* ((files (lispm-kernel-program--source-files)))
    (secure-hash 'sha256
                 (mapconcat (lambda (file)
                              (format "%s  %s\n" (lispm-kernel-program--sha256 file)
                                      (file-relative-name file lispm-kernel-program-source-directory)))
                            files ""))))

(defun lispm-kernel-program-source-version ()
  "Return the version of the program's sources, or nil without them: the
first 16 digits of `lispm-kernel-program-source-digest'.  A prebuilt
program is published, pinned and kept under it, so a program downloaded
for the sources stays current for them, and none is once they change."
  (when-let* ((digest (lispm-kernel-program-source-digest)))
    (substring digest 0 16)))

;;;; Pinned checksums

(defun lispm-kernel-program--sums-file ()
  "Return the file pinning the SHA-256 of the programs to download."
  (expand-file-name "lispm-kernel-program-sums.eld" lispm-kernel-program-lisp-directory))

(defun lispm-kernel-program--pins ()
  "Return what lispm-kernel-program-sums.eld pins: a plist whose :version
is the version of the sources pinned and :programs an alist of a SHA-256
for each target; nil when nothing is pinned."
  (let ((file (lispm-kernel-program--sums-file)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (let ((pins (ignore-errors (read (current-buffer)))))
          (and (listp pins) pins))))))

(defun lispm-kernel-program--pinned-sha256 (&optional target)
  "Return the SHA-256 pinned for the program of these sources for TARGET,
by default this computer's, or nil when none is pinned for them."
  (when-let* ((target (or target (lispm-kernel-program--target)))
              (version (lispm-kernel-program-source-version))
              (pins (lispm-kernel-program--pins))
              ((equal (plist-get pins :version) version))
              (sha256 (cdr (assoc target (plist-get pins :programs)))))
    (and (stringp sha256) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" sha256) sha256)))

;;;; Programs

(defun lispm-kernel-program--target (&optional configuration)
  "Return the target of the prebuilt program for a computer Emacs was built
for as CONFIGURATION, by default this one's `system-configuration', or nil
when none is published for it."
  (let ((configuration (or configuration system-configuration)))
    (cond ((string-match-p "\\`\\(?:aarch64\\|arm64\\)-apple-darwin" configuration) "aarch64-apple-darwin")
          ((string-match-p "\\`x86_64-apple-darwin" configuration) "x86_64-apple-darwin")
          ((string-match-p "\\`x86_64-[^-]+-linux-gnu\\'" configuration) "x86_64-unknown-linux-gnu"))))

(defun lispm-kernel-program--asset (target)
  "Return the name the program for TARGET is published under, compressed."
  (format "lispm-kernel-%s.gz" target))

(defun lispm-kernel-program--built-file ()
  "Return where SBCL builds the program."
  (expand-file-name "build/lispm-kernel" lispm-kernel-program-source-directory))

(defun lispm-kernel-program--built-p ()
  "Return non-nil when SBCL has built a program."
  (file-executable-p (lispm-kernel-program--built-file)))

(defun lispm-kernel-program--stale-p ()
  "Return non-nil when a source of the program is newer than the program
SBCL built, as after an update."
  (let ((program (lispm-kernel-program--built-file)))
    (and (file-exists-p program)
         (seq-some (lambda (file) (file-newer-than-file-p file program))
                   (lispm-kernel-program--source-files)))))

(defun lispm-kernel-program--prebuilt-directory ()
  "Return the directory downloaded programs are kept in, by version."
  (expand-file-name "prebuilt" lispm-kernel-program-source-directory))

(defun lispm-kernel-program--prebuilt-file ()
  "Return where the program downloaded for the sources is kept, whether it
is there or not, or nil when none is published for this computer or
there are no sources to name its version."
  (when-let* ((target (lispm-kernel-program--target))
              (version (lispm-kernel-program-source-version)))
    (expand-file-name (concat "lispm-kernel-" target)
                      (expand-file-name version (lispm-kernel-program--prebuilt-directory)))))

(defun lispm-kernel-program--building-p ()
  "Return non-nil when the program is to be built, not downloaded."
  (eq lispm-kernel-program-source 'build))

(defun lispm-kernel-program--current-file ()
  "Return a program current for the sources, or nil: when building, the one
SBCL built unless a source is newer; else the one downloaded for them.
A download is kept only once it was checked, so what is kept was."
  (if (lispm-kernel-program--building-p)
      (and (lispm-kernel-program--built-p) (not (lispm-kernel-program--stale-p))
           (lispm-kernel-program--built-file))
    (let ((prebuilt (lispm-kernel-program--prebuilt-file)))
      (and prebuilt (file-executable-p prebuilt) prebuilt))))

(defun lispm-kernel-program-file ()
  "Return the kernel program to run, or nil: a current one, see
`lispm-kernel-program--current-file', else, when building, the one SBCL
built, out of date.  Nothing is returned while it is being built or
downloaded."
  (unless (lispm-kernel-program-busy-p)
    (or (lispm-kernel-program--current-file)
        (and (lispm-kernel-program--building-p) (lispm-kernel-program--built-p)
             (lispm-kernel-program--built-file)))))

(defun lispm-kernel-program--plan ()
  "Return how to get the program: `build' when building is asked for, SBCL
and the sources are there, and the program SBCL built is missing or older
than a source; `download' otherwise, when no program checked for these
sources is there and one is pinned for this computer; else nil."
  (if (lispm-kernel-program--building-p)
      (and (executable-find "sbcl")
           (lispm-kernel-program--source-files)
           (or (not (lispm-kernel-program--built-p)) (lispm-kernel-program--stale-p))
           'build)
    (and (lispm-kernel-program--prebuilt-file)
         (not (lispm-kernel-program--current-file))
         (lispm-kernel-program--pinned-sha256)
         (executable-find "curl")
         (executable-find "gzip")
         'download)))

(defun lispm-kernel-program--why-not ()
  "Return why no program can be had, a sentence."
  (let ((version (lispm-kernel-program-source-version)))
    (cond ((lispm-kernel-program--building-p)
           (cond ((not version) "the kernel's sources, to build it from, are not there")
                 ((not (executable-find "sbcl")) "building it needs SBCL")
                 (t "SBCL built no program: see *lispm-kernel build*")))
          ((not (lispm-kernel-program--target))
           (format "none is published for %s" system-configuration))
          ((not version) "the kernel's sources, which name the program to download, are not there")
          ((not (lispm-kernel-program--pinned-sha256))
           (format "none is pinned for these sources (version %s); set `lispm-kernel-program-source' to `build' to build one"
                   version))
          ((not (executable-find "curl")) "downloading it needs curl")
          ((not (executable-find "gzip")) "unpacking it needs gzip")
          (t "none is there"))))

(defun lispm-kernel-program-busy-p ()
  "Return non-nil while the program is being built or downloaded.
That lasts until the process's sentinel has run, not only while it runs."
  (and (or lispm-kernel-program--building lispm-kernel-program--downloading) t))

(define-obsolete-function-alias 'lispm-kernel-program--busy-p #'lispm-kernel-program-busy-p "0.4.0")

(defun lispm-kernel-program--finish (what)
  "Say the program is there, it being WHAT, a word such as \"downloaded\",
or nil when it could not be got, and tell
`lispm-kernel-program-obtained-functions'."
  (let ((there (and what (lispm-kernel-program-file) t)))
    (if there
        (progn (setq lispm-kernel-program-problem nil)
               (message "lispm-kernel's program is %s" what))
      (setq lispm-kernel-program-problem
            (or lispm-kernel-program-problem (lispm-kernel-program--why-not))))
    (run-hook-with-args 'lispm-kernel-program-obtained-functions there)))

;;;; Building with SBCL, when asked to

(defun lispm-kernel-program-build ()
  "Build the program with SBCL in the background.
Its output is in the *lispm-kernel build* buffer.  This is how the program
is got when `lispm-kernel-program-source' is `build'."
  (interactive)
  (unless (and (executable-find "sbcl") (lispm-kernel-program--source-files))
    (user-error "Building lispm-kernel's program needs SBCL and the kernel's sources"))
  (unless lispm-kernel-program--building
    (let ((default-directory (file-name-as-directory lispm-kernel-program-source-directory))
          (process-environment (cons (concat "LISPM_KERNEL_OUTPUT=" (lispm-kernel-program--built-file))
                                     process-environment))
          (buffer (get-buffer-create "*lispm-kernel build*")))
      (with-current-buffer buffer (erase-buffer))
      (message "Building lispm-kernel's program…")
      (setq lispm-kernel-program-problem nil
            lispm-kernel-program--stopped nil
            lispm-kernel-program--building
            (make-process
             :name "lispm-kernel build" :buffer buffer :noquery t
             :command '("sbcl" "--non-interactive" "--no-sysinit" "--no-userinit"
                        "--load" "scripts/build.lisp")
             :sentinel
             (lambda (process _event)
               (unless (process-live-p process)
                 (setq lispm-kernel-program--building nil)
                 (cond ((lispm-kernel-program--stopped-p)
                        (setq lispm-kernel-program-problem "building it was stopped")
                        (lispm-kernel-program--finish nil))
                       ((and (= (process-exit-status process) 0) (lispm-kernel-program--built-p))
                        (lispm-kernel-program--finish "built"))
                       (t
                        (setq lispm-kernel-program-problem "SBCL could not build it: see *lispm-kernel build*")
                        (message "lispm-kernel's program could not be built: see %s" "*lispm-kernel build*")
                        (lispm-kernel-program--finish nil))))))))))

;;;; Downloading, checked

(defun lispm-kernel-program--install (program file)
  "Keep the unpacked PROGRAM as FILE, executable, and remove the programs
kept for other versions; return FILE."
  (let ((directory (directory-file-name (file-name-directory file))))
    (make-directory directory t)
    ;; Renamed into place, so the program is there whole or not at all.
    (copy-file program (concat file ".part") t)
    (set-file-modes (concat file ".part") #o755)
    (rename-file (concat file ".part") file t)
    (dolist (old (directory-files (lispm-kernel-program--prebuilt-directory) t "\\`[^.]"))
      (when (and (file-directory-p old) (not (string= old directory)))
        (delete-directory old t)))
    file))

(defun lispm-kernel-program--run (name buffer command then &optional filter)
  "Run COMMAND as the process NAME, its output in BUFFER, in the background;
call THEN with whether it exited with 0.  FILTER, when given, takes the
output instead.  Return the process."
  (make-process
   :name name :buffer buffer :noquery t :command command :filter filter
   :sentinel (lambda (process _event)
               (unless (process-live-p process)
                 (funcall then (= (process-exit-status process) 0))))))

(defun lispm-kernel-program--progress (fraction)
  "Say that FRACTION of the program is there, a number from 0 to 1, or
nil when nothing downloads."
  (unless (equal fraction lispm-kernel-program-progress)
    (setq lispm-kernel-program-progress fraction)
    (when fraction
      (run-hook-with-args 'lispm-kernel-program-progress-functions fraction))))

(defconst lispm-kernel-program--bar-regexp
  "\\`[-#=O ]*?\\([0-9]+\\(?:[.,][0-9]+\\)?\\)%\\'"
  "What curl's progress bar says once it knows the size: hashes, then the
percentage.")

(defun lispm-kernel-program--curl-filter (buffer)
  "Return the filter of a curl drawing its progress bar: the percentages go
to `lispm-kernel-program--progress', the bar's other frames nowhere, and
the rest, as curl's errors, into BUFFER."
  (let ((partial ""))
    (lambda (_process output)
      (let* ((pieces (split-string (concat partial output) "[\r\n]"))
             (last (car (last pieces))))
        (setq partial last)
        (dolist (piece (append (butlast pieces)
                               ;; A frame of the bar is whole before the next \r.
                               (and (string-match-p lispm-kernel-program--bar-regexp last) (list last))))
          (let ((piece (string-trim piece)))
            (cond ((string-match lispm-kernel-program--bar-regexp piece)
                   (lispm-kernel-program--progress
                    (min 1.0 (/ (string-to-number (string-replace "," "." (match-string 1 piece))) 100.0))))
                  ((string-match-p "\\`[-#=O ]*\\'" piece))
                  ((buffer-live-p buffer)
                   (with-current-buffer buffer
                     (goto-char (point-max))
                     (insert piece "\n"))))))))))

(defun lispm-kernel-program--stopped-p ()
  "Return non-nil, once, when `lispm-kernel-program-stop' stopped the
build or download whose sentinel asks."
  (prog1 lispm-kernel-program--stopped
    (setq lispm-kernel-program--stopped nil)))

(defun lispm-kernel-program-stop ()
  "Stop building or downloading the program; nothing of it is kept.
Those waiting for it hear that it is not there, and
`lispm-kernel-program-problem' says it was stopped."
  (interactive)
  (dolist (process (list lispm-kernel-program--building lispm-kernel-program--downloading))
    (when (process-live-p process)
      (setq lispm-kernel-program--stopped t)
      ;; Its sentinel runs now, and ends it.
      (delete-process process))))

(defun lispm-kernel-program-download ()
  "Download the program built for this computer from the sources there
are, in the background, check it against the SHA-256 pinned for it, and
unpack it.  It comes from `lispm-kernel-program-prebuilt-url'; what went
wrong, if anything, is in `lispm-kernel-program-problem' and the
*lispm-kernel download* buffer."
  (interactive)
  (let ((file (lispm-kernel-program--prebuilt-file))
        (sha256 (lispm-kernel-program--pinned-sha256)))
    (unless (and file sha256 (executable-find "curl") (executable-find "gzip"))
      (user-error "No lispm-kernel program can be downloaded: %s" (lispm-kernel-program--why-not)))
    (unless lispm-kernel-program--downloading
      (let* ((asset (lispm-kernel-program--asset (lispm-kernel-program--target)))
             (url (format "%s/kernel-program-%s/%s"
                          (string-trim-right lispm-kernel-program-prebuilt-url "/+")
                          (lispm-kernel-program-source-version) asset))
             (directory (make-temp-file "lispm-kernel" t))
             (compressed (expand-file-name asset directory))
             (buffer (get-buffer-create "*lispm-kernel download*")))
        (with-current-buffer buffer (erase-buffer))
        (message "Downloading lispm-kernel's program…")
        (setq lispm-kernel-program-problem nil
              lispm-kernel-program--stopped nil
              lispm-kernel-program-progress nil)
        (cl-labels
            ((done (problem)
               (setq lispm-kernel-program--downloading nil
                     lispm-kernel-program-progress nil)
               (delete-directory directory t)
               (when problem
                 (setq lispm-kernel-program-problem problem)
                 (when (buffer-live-p buffer)
                   (with-current-buffer buffer (insert problem "\n")))
                 (message "lispm-kernel's program: %s" problem))
               (lispm-kernel-program--finish (and (not problem) "downloaded")))
             (unpacked (ok)
               (condition-case error
                   (cond
                    ((lispm-kernel-program--stopped-p) (done "downloading it was stopped"))
                    ((not ok)
                     (done "it could not be unpacked: see *lispm-kernel download*"))
                    (t
                     (lispm-kernel-program--install (file-name-sans-extension compressed) file)
                     (done nil)))
                 (error (done (error-message-string error)))))
             (downloaded (ok)
               (cond ((lispm-kernel-program--stopped-p) (done "downloading it was stopped"))
                     ((not ok)
                      (done (format "it could not be downloaded from %s: %s" url
                                    (if (buffer-live-p buffer)
                                        (with-current-buffer buffer (string-trim (buffer-string)))
                                      ""))))
                     ((not (equal (lispm-kernel-program--sha256 compressed) sha256))
                      (done (format "%s is not the program pinned for these sources: its SHA-256 differs, so it was refused"
                                    asset)))
                     (t
                      (setq lispm-kernel-program--downloading
                            (lispm-kernel-program--run "lispm-kernel unpack" buffer
                                                       (list "gzip" "-d" "-f" compressed)
                                                       #'unpacked))))))
          (setq lispm-kernel-program--downloading
                (lispm-kernel-program--run "lispm-kernel download" buffer
                                           (list "curl" "--fail" "--progress-bar" "--show-error" "--location"
                                                 "--retry" "2" "--output" compressed url)
                                           #'downloaded (lispm-kernel-program--curl-filter buffer))))))))

;;;; Getting it

(defun lispm-kernel-program-obtain ()
  "Get the program without blocking Emacs, and say how it went.
Return `ready' when it is there now; `pending' while it is downloaded, or
built, in the background, see `lispm-kernel-program--plan', the functions
of `lispm-kernel-program-obtained-functions' being called once that
ends; nil when there is none and none can be had, and
`lispm-kernel-program-problem' then says why."
  (cond ((lispm-kernel-program-busy-p) 'pending)
        ((pcase (lispm-kernel-program--plan)
           ('build (lispm-kernel-program-build) t)
           ('download (lispm-kernel-program-download) t))
         'pending)
        ((lispm-kernel-program-file) (setq lispm-kernel-program-problem nil) 'ready)
        (t (setq lispm-kernel-program-problem (lispm-kernel-program--why-not))
           nil)))

;;;; In batch: an installer's or a workflow's

(defun lispm-kernel-program--wait ()
  (while (lispm-kernel-program-busy-p)
    (accept-process-output nil 0.1)))

(defun lispm-kernel-program--check (program)
  "Return non-nil when PROGRAM runs and says hello in this Lisp's protocol."
  (let ((runtime (lispm-kernel-start program))
        (deadline (+ (float-time) 30)))
    (unwind-protect
        (progn
          (while (and (null (lispm-kernel-runtime-hello runtime))
                      (lispm-kernel-live-p runtime)
                      (< (float-time) deadline))
            (accept-process-output (lispm-kernel-runtime-process runtime) 0.1)
            (lispm-kernel-dispatch runtime))
          (and (lispm-kernel-live-p runtime)
               (eql (plist-get (lispm-kernel-runtime-hello runtime) :protocol) lispm-kernel-protocol)))
      (lispm-kernel-stop runtime))))

(defun lispm-kernel-program-batch-download ()
  "Download the program, unless one checked for its sources is there, for
an installer or a workflow running Emacs in batch: Emacs then exits with
0 once the program runs and speaks this Lisp's protocol, else 1, having
said what went wrong."
  (unless (lispm-kernel-program--current-file)
    (if (not (lispm-kernel-program--plan))
        (message "No lispm-kernel program can be downloaded: %s" (lispm-kernel-program--why-not))
      (lispm-kernel-program-download)
      (lispm-kernel-program--wait)))
  (let ((program (lispm-kernel-program-file)))
    (kill-emacs (if (and program (lispm-kernel-program--check program)) 0 1))))

(defun lispm-kernel-program--fetch (url file)
  "Download URL into FILE with curl, or signal an error."
  (unless (zerop (call-process "curl" nil nil nil "--fail" "--silent" "--show-error" "--location"
                               "--retry" "2" "--output" file url))
    (error "Could not download %s" url)))

(defun lispm-kernel-program-published (url version)
  "Return the alist of target and SHA-256 of the release of VERSION under
URL, each program downloaded and found to be the one its SHA256SUMS
lists, and one there for every target in `lispm-kernel-program-targets'.
Signal an error otherwise."
  (let* ((release (format "%s/kernel-program-%s/" (string-trim-right url "/+") version))
         (directory (make-temp-file "lispm-kernel-pin" t))
         (sums (expand-file-name "SHA256SUMS" directory))
         (programs nil))
    (unwind-protect
        (progn
          (lispm-kernel-program--fetch (concat release "SHA256SUMS") sums)
          (dolist (line (split-string (with-temp-buffer (insert-file-contents sums) (buffer-string))
                                      "\n" t "[ \t\r]+"))
            (unless (string-match "\\`\\([0-9a-f]\\{64\\}\\) [ *]lispm-kernel-\\(.+\\)\\.gz\\'" line)
              (error "SHA256SUMS of kernel-program-%s lists %S, not a kernel program" version line))
            (let* ((sha256 (match-string 1 line))
                   (target (match-string 2 line))
                   (file (expand-file-name (lispm-kernel-program--asset target) directory)))
              (lispm-kernel-program--fetch (concat release (lispm-kernel-program--asset target)) file)
              (unless (equal (lispm-kernel-program--sha256 file) sha256)
                (error "%s is not the program SHA256SUMS lists: refusing to pin it"
                       (lispm-kernel-program--asset target)))
              (push (cons target sha256) programs)))
          (let ((missing (seq-remove (lambda (target) (assoc target programs))
                                     lispm-kernel-program-targets)))
            (when missing
              (error "kernel-program-%s has no program for %s" version (string-join missing ", "))))
          (sort programs (lambda (a b) (string< (car a) (car b)))))
      (delete-directory directory t))))

(defun lispm-kernel-program--render-pins (version programs)
  (concat ";;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

"
          (format "(:version %S\n :programs (%s))\n" version
                  (mapconcat (lambda (program) (format "(%S . %S)" (car program) (cdr program)))
                             programs "\n            "))))

(defun lispm-kernel-program-batch-pin ()
  "Pin the published programs of these sources, for Emacs in batch.
It writes lispm-kernel-program-sums.eld from the release
kernel-program-VERSION under `lispm-kernel-program-prebuilt-url', each
program checked against the release's SHA256SUMS; run it once the
workflow has published the release, and commit the file with a change of
lispm-kernel.el's Version header.  With LISPM_KERNEL_PIN_CHECK set it
writes nothing and exits with 1 when the file pins these sources
otherwise than the release has them; a file pinning other sources
passes, with a notice, as it does between a change of the sources and
the next release."
  (let ((version (or (lispm-kernel-program-source-version) (error "No sources here")))
        (pins (lispm-kernel-program--pins))
        (file (lispm-kernel-program--sums-file)))
    (condition-case error
        (if (getenv "LISPM_KERNEL_PIN_CHECK")
            (cond ((not (equal (plist-get pins :version) version))
                   (message "::notice::%s pins %s, not the sources' %s: pin it once kernel-program-%s is published"
                            (file-name-nondirectory file)
                            (if (plist-get pins :version)
                                (format "kernel-program-%s" (plist-get pins :version))
                              "nothing")
                            version version))
                  ((equal (lispm-kernel-program-published lispm-kernel-program-prebuilt-url version)
                          (sort (copy-sequence (plist-get pins :programs))
                                (lambda (a b) (string< (car a) (car b)))))
                   (message "%s pins kernel-program-%s as published" (file-name-nondirectory file) version))
                  (t (error "%s differs from the release kernel-program-%s"
                            (file-name-nondirectory file) version)))
          (with-temp-file file
            (insert (lispm-kernel-program--render-pins
                     version (lispm-kernel-program-published lispm-kernel-program-prebuilt-url version))))
          (message "%s pins kernel-program-%s" (file-name-nondirectory file) version))
      (error (message "%s" (error-message-string error))
             (kill-emacs 1)))
    (kill-emacs 0)))

(provide 'lispm-kernel-program)
;;; lispm-kernel-program.el ends here
