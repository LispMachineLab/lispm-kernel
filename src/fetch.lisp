;;;; fetch.lisp --- Downloads Emacs does not wait on

;; Copyright (C) 2026  Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

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

;;; Emacs downloads with url.el in its own process, and negotiates TLS on
;;; its own thread.  The fetch job downloads instead, with curl, which
;;; the kernel runs; SBCL speaks no TLS of its own:
;;;
;;;   Emacs  (submit 9 fetch (:url "https://..." :file "/tmp/x" :proxy nil))
;;;   kernel (done 9 success 2639466)
;;;
;;; FILE gets what URL holds, and the result is its size in bytes.  PROXY
;;; is the proxy url.el would reach URL through, "http://HOST:PORT/", or
;;; nil for none: curl then uses no proxy of the environment either.
;;; Only http and https are fetched, redirections too, compressed on the
;;; way when the server can, as url.el asks for it.  A download that
;;; fails fails its request with what curl said; one that is cancelled
;;; stops curl.  Either removes FILE.

(in-package #:lispm-kernel)

(defparameter *fetch-protocols* "=http,https"
  "The protocols curl may fetch with, and be redirected to, as its --proto
option takes them.")

(defun fetch-arguments (url file &key proxy timeout)
  "Return curl's arguments to download URL into FILE, through PROXY or
none, giving up after TIMEOUT seconds when given."
  (append (list "--fail" "--silent" "--show-error" "--location" "--compressed"
                "--proto" *fetch-protocols* "--proto-redir" *fetch-protocols*
                "--output" file)
          (if proxy
              (list "--proxy" proxy)
              (list "--noproxy" "*"))
          (when timeout
            (list "--max-time" (princ-to-string timeout)))
          (list "--url" url)))

(defun curl-failure (process)
  "Return why PROCESS, curl, failed: the last line it said, else its code."
  (let ((said (ignore-errors
               (loop with last = nil
                     for line = (read-line (sb-ext:process-error process) nil nil)
                     while line
                     unless (zerop (length (string-trim " " line)))
                       do (setf last (string-trim " " line))
                     finally (return last)))))
    (or said (format nil "curl exited with code ~D" (sb-ext:process-exit-code process)))))

(define-job (fetch :class :io) (input)
  "Download URL into FILE, through PROXY or none, in at most TIMEOUT
seconds; return FILE's size.  INPUT is a plist of them."
  (destructuring-bind (&key url file proxy (timeout 300)) input
    (check-type url string)
    (check-type file string)
    (check-type proxy (or null string))
    (check-type timeout (integer 1 3600))
    (let ((process (sb-ext:run-program "curl" (fetch-arguments url file :proxy proxy :timeout timeout)
                                       :search t :wait nil :input nil :output nil :error :stream
                                       :external-format '(:utf-8 :replacement #\?)))
          (fetched nil))
      (unwind-protect
           (progn
             (loop while (sb-ext:process-alive-p process)
                   do (checkpoint)
                      (sleep 0.01))
             (unless (eql (sb-ext:process-exit-code process) 0)
               (error "~A" (curl-failure process)))
             (prog1 (sb-posix:stat-size (sb-posix:stat file))
               (setf fetched t)))
        (when (sb-ext:process-alive-p process)
          (sb-ext:process-kill process sb-posix:sigterm)
          (sb-ext:process-wait process))
        (sb-ext:process-close process)
        (unless fetched
          (ignore-errors (sb-posix:unlink file)))))))
