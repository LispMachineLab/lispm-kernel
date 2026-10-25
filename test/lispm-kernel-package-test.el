;;; lispm-kernel-package-test.el --- package.el's downloads through the kernel -*- lexical-binding: t; -*-

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

;; These run the kernel program LISPM_KERNEL_PROGRAM names, which fetches
;; from an HTTP server this Emacs runs on a local port: nothing reaches
;; the network.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'package)
(require 'url)
(require 'lispm-kernel-test)
(require 'lispm-kernel-package)

(defconst lispm-kernel-package-test--archive "(1 (ack . [(1 0) nil \"A package\" tar]))"
  "An archive's contents, as the server serves them.")

(defun lispm-kernel-package-test--serve (routes)
  "Serve ROUTES, (PATH . BODY), over HTTP on a free local port, any other
path as not found; return the server's URL, ending with a slash."
  (let ((server (make-network-process
                 :name "lispm-kernel-package-test" :server t :host 'local :service t
                 :family 'ipv4 :coding 'binary :noquery t
                 :filter (lambda (process text)
                           (when (string-match "\\`GET \\([^ ]+\\)" text)
                             (let ((body (cdr (assoc (match-string 1 text) routes))))
                               (process-send-string
                                process
                                (if body
                                    (format "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s"
                                            (string-bytes body) body)
                                  "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
                               (process-send-eof process)))))))
    (format "http://127.0.0.1:%d/" (process-contact server :service))))

(defmacro lispm-kernel-package-test--with (spec &rest body)
  "Run BODY with the mode on, a kernel of the program under test, a server
of ROUTES, url.el's downloads counted, and temporary files in a directory
of their own.  SPEC is (RUNTIME URL CALLS DIRECTORY ROUTES)."
  (declare (indent 1))
  (pcase-let ((`(,runtime ,url ,calls ,directory ,routes) spec))
    `(let* ((,directory (make-temp-file "lispm-kernel-package-test" t))
            (temporary-file-directory (file-name-as-directory ,directory))
            (,url (lispm-kernel-package-test--serve ,routes))
            (,calls nil)
            (url-proxy-services nil)
            (process-environment (append '("http_proxy" "https_proxy" "HTTP_PROXY" "HTTPS_PROXY")
                                         process-environment))
            (was-on lispm-kernel-package-mode))
       (lispm-kernel-test--with-runtime ,runtime
         (let ((lispm-kernel-package-runtime-function (lambda () ,runtime)))
           (lispm-kernel-test--wait ,runtime (lambda () (lispm-kernel-runtime-hello ,runtime)))
           (unwind-protect
               (cl-letf (((symbol-function 'url-retrieve)
                          (lambda (location &rest _) (push location ,calls) nil)))
                 (lispm-kernel-package-mode 1)
                 ,@body)
             (unless was-on (lispm-kernel-package-mode -1))
             (dolist (process (process-list))
               (when (string-prefix-p "lispm-kernel-package-test" (process-name process))
                 (delete-process process)))
             (delete-directory ,directory t)))))))

(defun lispm-kernel-package-test--get (url file &rest keys)
  "Ask package.el for FILE at URL in the background, with KEYS; return a
cons whose car becomes (BODY-SAW) or (FAILED), once it is done."
  (let ((outcome (list nil)))
    (apply #'package--with-response-buffer-1 url
           (lambda () (setcar outcome (list (list (buffer-string) enable-multibyte-characters (point)))))
           :async t :file file
           :error-function (lambda () (setcar outcome (list 'failed enable-multibyte-characters)))
           keys)
    outcome))

(ert-deftest lispm-kernel-package-fetches-for-package-el ()
  "A download package.el makes in the background is the kernel's: its body
sees what was served, unibyte, from the start, and the file is gone."
  (lispm-kernel-package-test--with (runtime url calls directory
                                    `(("/packages/archive-contents" . ,lispm-kernel-package-test--archive)))
    (let ((outcome (lispm-kernel-package-test--get (concat url "packages/") "archive-contents")))
      (should (lispm-kernel-test--wait runtime (lambda () (car outcome))))
      (should (equal (car outcome) `((,lispm-kernel-package-test--archive nil 1))))
      (should-not calls)
      (should-not (directory-files directory nil "\\`lispm-kernel-fetch-")))))

(ert-deftest lispm-kernel-package-failures-reach-package-el ()
  "A download that fails calls the error function, in a unibyte buffer as
package.el's own have it, and is an error unless package.el said not to
mind; the file is gone either way."
  (lispm-kernel-package-test--with (runtime url calls directory nil)
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest arguments)
                   (push (apply #'format-message format arguments) messages))))
        (let ((outcome (lispm-kernel-package-test--get url "archive-contents.sig")))
          (should (lispm-kernel-test--wait runtime (lambda () (and (car outcome) messages))))
          (should (equal (car outcome) '(failed nil)))
          (should (string-match-p "\\`Error retrieving: .*archive-contents\\.sig" (car messages))))
        (setq messages nil)
        (let ((quiet (lispm-kernel-package-test--get url "archive-contents.sig" :noerror t)))
          (should (lispm-kernel-test--wait runtime (lambda () (car quiet))))
          (should (equal (car quiet) '(failed nil)))
          (should-not messages)))
      (should-not calls)
      (should-not (directory-files directory nil "\\`lispm-kernel-fetch-")))))

(ert-deftest lispm-kernel-package-leaves-url-el-the-rest ()
  "url.el downloads what the kernel does not: while asked to wait, from a
file, through SOCKS, or while no kernel that knows the job runs."
  (lispm-kernel-package-test--with (runtime url calls directory
                                    `(("/archive-contents" . ,lispm-kernel-package-test--archive)))
    ;; Waiting: url.el, and its answer at once.
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (location &rest _) (push location calls) nil)))
      (should-error (package--with-response-buffer-1 url #'ignore :file "archive-contents"
                                                     :error-function #'ignore)))
    (should (equal calls (list (concat url "archive-contents"))))
    (setq calls nil)
    ;; A file.
    (let ((file (expand-file-name "archive-contents" directory))
          (seen nil))
      (with-temp-file file (insert "contents"))
      (package--with-response-buffer-1 (file-name-as-directory directory)
                                       (lambda () (setq seen (buffer-string)))
                                       :async t :file "archive-contents" :error-function #'ignore)
      (should (equal seen "contents")))
    ;; Through SOCKS, as url.el would go.
    (let ((url-proxy-services '(("http" . "127.0.0.1:1")))
          (url-proxy-locator (lambda (&rest _) "SOCKS 127.0.0.1:1080")))
      (lispm-kernel-package-test--get url "archive-contents"))
    ;; A kernel that does not know the job, and none at all.
    (setf (lispm-kernel-runtime-hello runtime)
          (plist-put (copy-sequence (lispm-kernel-runtime-hello runtime)) :jobs '(:echo)))
    (lispm-kernel-package-test--get url "archive-contents")
    (let ((lispm-kernel-package-runtime-function #'ignore))
      (lispm-kernel-package-test--get url "archive-contents"))
    (should (equal calls (make-list 3 (concat url "archive-contents"))))
    (should-not (directory-files directory nil "\\`lispm-kernel-fetch-"))))

(ert-deftest lispm-kernel-package-reaches-urls-as-url-el-would ()
  "The kernel goes through the proxy url.el would use, directly where it
would, and leaves it a URL it would reach another way."
  (let ((url-proxy-services '(("no_proxy" . "\\(localhost\\|127\\.0\\.0\\.1\\)")
                              ("https" . "127.0.0.1:6152")))
        (url-gateway-method 'native))
    (should (equal (lispm-kernel-package--proxy "https://melpa.org/packages/archive-contents")
                   '(proxy "http://127.0.0.1:6152/")))
    (should (equal (lispm-kernel-package--proxy "http://elpa.gnu.org/packages/") '(direct)))
    (should (equal (lispm-kernel-package--proxy "https://127.0.0.1/a") '(direct)))
    (let ((url-proxy-locator (lambda (&rest _) "SOCKS 127.0.0.1:1080")))
      (should-not (lispm-kernel-package--proxy "https://melpa.org/")))
    (let ((url-gateway-method 'socks))
      (should-not (lispm-kernel-package--proxy "https://melpa.org/")))))

(ert-deftest lispm-kernel-package-refreshes-archives ()
  "package.el refreshes its archives in the background through the kernel,
and keeps and reads them as it always does."
  (lispm-kernel-package-test--with (runtime url calls directory
                                    `(("/archive-contents" . ,lispm-kernel-package-test--archive)))
    (let ((package-user-dir (expand-file-name "elpa" directory))
          (package-check-signature nil)
          (package-archives `(("test" . ,url)))
          (package-archive-contents nil)
          (package--downloads-in-progress nil)
          (inhibit-message t))
      (package-refresh-contents t)
      (should (lispm-kernel-test--wait runtime (lambda () (null package--downloads-in-progress))))
      (should (equal (with-temp-buffer
                       (insert-file-contents (expand-file-name "archives/test/archive-contents"
                                                               package-user-dir))
                       (buffer-string))
                     lispm-kernel-package-test--archive))
      (should (assq 'ack package-archive-contents))
      (should-not calls))))

(defvar lispm-prebuilt-fetch-function)

(ert-deftest lispm-kernel-package-fetches-for-lispm-prebuilt ()
  "lispm-prebuilt's downloads are the kernel's while the mode is on: the
file holds what was served, and a failure says why and leaves no file.
What the kernel cannot fetch is left to lispm-prebuilt, and so is all of
it once the mode is off."
  (let ((had (boundp 'lispm-prebuilt-fetch-function))
        (old (bound-and-true-p lispm-prebuilt-fetch-function))
        (curled nil))
    (unwind-protect
        (progn
          (setq lispm-prebuilt-fetch-function
                (lambda (url _file callback &rest _) (push url curled) (funcall callback "curl")))
          (lispm-kernel-package-test--with (runtime url calls directory '(("/module.gz" . "the module")))
            (let ((file (expand-file-name "module.gz" directory))
                  (missing (expand-file-name "missing.gz" directory))
                  (heard 'pending))
              (funcall lispm-prebuilt-fetch-function (concat url "module.gz") file
                       (lambda (why) (setq heard why)) :timeout 30)
              (should (lispm-kernel-test--wait runtime (lambda () (not (eq heard 'pending)))))
              (should-not heard)
              (should (equal (with-temp-buffer (insert-file-contents-literally file) (buffer-string))
                             "the module"))
              (setq heard 'pending)
              (funcall lispm-prebuilt-fetch-function (concat url "missing.gz") missing
                       (lambda (why) (setq heard why)))
              (should (lispm-kernel-test--wait runtime (lambda () (not (eq heard 'pending)))))
              (should (string-match-p "\\`Could not download .*missing\\.gz" heard))
              (should-not (file-exists-p missing))
              (should-not curled)
              (should-not calls)
              ;; Not http or https: lispm-prebuilt's own.
              (funcall lispm-prebuilt-fetch-function "file:///nowhere" file #'ignore)
              (should (equal curled '("file:///nowhere")))
              (lispm-kernel-package-mode -1)
              (funcall lispm-prebuilt-fetch-function (concat url "module.gz") file #'ignore)
              (should (equal curled (list (concat url "module.gz") "file:///nowhere"))))))
      (lispm-kernel-package-mode -1)
      (if had
          (setq lispm-prebuilt-fetch-function old)
        (makunbound 'lispm-prebuilt-fetch-function)))))

(ert-deftest lispm-kernel-package-mode-advises-only-while-on ()
  (let ((was-on lispm-kernel-package-mode))
    (unwind-protect
        (progn
          (lispm-kernel-package-mode 1)
          (should (advice-member-p #'lispm-kernel-package--with-response-buffer
                                   'package--with-response-buffer-1))
          (lispm-kernel-package-mode -1)
          (should-not (advice-member-p #'lispm-kernel-package--with-response-buffer
                                       'package--with-response-buffer-1)))
      (lispm-kernel-package-mode (if was-on 1 -1)))))

(provide 'lispm-kernel-package-test)
;;; lispm-kernel-package-test.el ends here
