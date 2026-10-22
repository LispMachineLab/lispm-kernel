;;; lispm-kernel-package.el --- package.el's downloads, made by the kernel -*- lexical-binding: t; -*-

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

;; package.el downloads the package archives, their signatures and the
;; packages with url.el, in Emacs's own process.  Even in the background,
;; as `package-refresh-contents' does when asked to, url.el negotiates TLS
;; on Emacs's thread, and through a proxy it waits for the handshake:
;; Emacs freezes for most of a second, once a download.
;;
;; `lispm-kernel-package-mode' hands those downloads to the kernel, whose
;; `fetch' job runs curl on a thread of its own and writes what it got to a
;; file, and gives package.el that file's contents as url.el would have
;; given it the response.  package.el does the rest as it always does:
;; checks the signatures, keeps the archives, installs.  Every download
;; goes through `package--with-response-buffer-1', which the mode advises.
;;
;; Only downloads package.el makes in the background go to the kernel,
;; and only from http and https, through the proxy url.el would use for
;; them.  The others, those url.el would reach through SOCKS or a gateway
;; of its own, and all of them while no kernel that knows the job runs,
;; as before its program is there, url.el downloads as it does without
;; the mode.

;;; Code:

(require 'cl-lib)
(require 'lispm-kernel)
(require 'url-parse)

(defvar url-gateway-method)
(declare-function url-do-setup "url" ())
(declare-function url-expand-file-name "url-expand" (url &optional default))
(declare-function url-find-proxy-for-url "url-proxy" (url host))
(defvar lispm-kernel-desktop-mode)
(declare-function lispm-kernel-desktop-runtime "lispm-kernel-desktop" ())

(defcustom lispm-kernel-package-timeout 300
  "Seconds a download may take before package.el hears it failed."
  :type 'integer :group 'lispm-kernel)

(defvar lispm-kernel-package-runtime-function #'lispm-kernel-package--desktop-runtime
  "Function returning the runtime whose kernel downloads, or nil for none.")

(defconst lispm-kernel-package--owner 3
  "The owner of the kernel's requests for package.el, after the agents'.")

(defun lispm-kernel-package--desktop-runtime ()
  "Return the desktop's kernel while `lispm-kernel-desktop-mode' runs it."
  (and (bound-and-true-p lispm-kernel-desktop-mode)
       (fboundp 'lispm-kernel-desktop-runtime)
       (lispm-kernel-desktop-runtime)))

(defun lispm-kernel-package--runtime ()
  "Return a runtime whose kernel runs and knows the `fetch' job, or nil."
  (when-let* ((runtime (and lispm-kernel-package-runtime-function
                            (funcall lispm-kernel-package-runtime-function))))
    (and (lispm-kernel-live-p runtime)
         (memq :fetch (plist-get (lispm-kernel-runtime-hello runtime) :jobs))
         runtime)))

(defun lispm-kernel-package--proxy (url)
  "Return how url.el would reach URL: (proxy PROXY), PROXY \"http://HOST:PORT/\",
\(direct), or nil when it would go another way, through SOCKS or a
gateway of its own."
  (require 'url)
  (url-do-setup)
  (let* ((parsed (url-generic-parse-url url))
         (proxy (url-find-proxy-for-url parsed (url-host parsed))))
    (cond ((not (eq url-gateway-method 'native)) nil)
          ((null proxy) '(direct))
          ((string-prefix-p "http://" proxy) (list 'proxy proxy)))))

(defun lispm-kernel-package--deliver (url file body error-function noerror status value)
  "Run BODY with what the kernel fetched from URL into FILE, or say why not.
STATUS and VALUE are how its request ended.  Both BODY and, for a
failure, ERROR-FUNCTION run in a unibyte buffer, BODY's holding what was
fetched, point at the start, as package.el runs them with what url.el
got; a failure is an error, unless NOERROR.  What goes wrong is said, as
url.el's callback would say it."
  (unwind-protect
      (condition-case err
          (with-temp-buffer
            (set-buffer-multibyte nil)
            (if (eq status 'success)
                (progn (insert-file-contents-literally file)
                       (goto-char (point-min))
                       (funcall body))
              (funcall error-function)
              (unless noerror
                (error "Error retrieving: %s %S" url (list status value)))))
        (error (message "%s" (error-message-string err))))
    (ignore-errors (delete-file file))))

(cl-defun lispm-kernel-package--with-response-buffer
    (original url body &rest keys &key async file error-function noerror &allow-other-keys)
  "Have the kernel fetch URL, with FILE added, then run BODY, when ASYNC.
This is around ORIGINAL, `package--with-response-buffer-1', which KEYS go
to as they came when the kernel cannot fetch: see its ERROR-FUNCTION and
NOERROR."
  (let* ((runtime (and async (string-match-p "\\`https?:" url) (lispm-kernel-package--runtime)))
         (location (and runtime (url-expand-file-name file url)))
         (route (and runtime (lispm-kernel-package--proxy location)))
         (target (and route (make-temp-file "lispm-kernel-fetch-"))))
    (if (not target)
        (apply original url body keys)
      (condition-case nil
          (progn
            (lispm-kernel-submit
             runtime 'fetch (list :url location :file target :proxy (cadr route)
                                  :timeout lispm-kernel-package-timeout)
             :owner lispm-kernel-package--owner
             ;; The kernel's own deadline comes first, curl's then its.
             :timeout (+ lispm-kernel-package-timeout 10)
             :on-result (lambda (kind value)
                          (unless (eq kind 'chunk)
                            (lispm-kernel-package--deliver
                             location target body error-function noerror kind value))))
            nil)
        ;; The kernel went away meanwhile: url.el downloads.
        (error (ignore-errors (delete-file target))
               (apply original url body keys))))))

;;;###autoload
(define-minor-mode lispm-kernel-package-mode
  "Have the kernel make the downloads package.el makes in the background.
The kernel is the one `lispm-kernel-package-runtime-function' returns,
by default the desktop's while `lispm-kernel-desktop-mode' runs it; while
none that knows the `fetch' job runs, url.el downloads, as without the
mode.  package.el checks and keeps what is fetched as it always does."
  :global t :group 'lispm-kernel
  (if lispm-kernel-package-mode
      (advice-add 'package--with-response-buffer-1 :around
                  #'lispm-kernel-package--with-response-buffer)
    (advice-remove 'package--with-response-buffer-1
                   #'lispm-kernel-package--with-response-buffer)))

(provide 'lispm-kernel-package)
;;; lispm-kernel-package.el ends here
