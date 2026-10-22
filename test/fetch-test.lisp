;;;; fetch-test.lisp --- Tests of the downloads curl makes for Emacs

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

;;; The downloads go to file: URLs, which the tests let curl fetch, so
;;; that nothing reaches the network.

(in-package #:lispm-kernel/test)

(defun file-url (path)
  (concatenate 'string "file://" path))

(defun there-p (path)
  (and (probe-file (sb-ext:parse-native-namestring path)) t))

(defun after (option arguments)
  "Return the argument after OPTION in ARGUMENTS."
  (second (member option arguments :test #'string=)))

(deftest fetch-arguments ()
  (let ((direct (lispm-kernel::fetch-arguments "https://elpa.gnu.org/packages/archive-contents" "/tmp/a"))
        (proxied (lispm-kernel::fetch-arguments "https://elpa.gnu.org/packages/archive-contents" "/tmp/a"
                                                :proxy "http://127.0.0.1:6152/" :timeout 30)))
    ;; No proxy is none, the environment's neither.
    (is (equal "*" (after "--noproxy" direct)))
    (is (null (member "--proxy" direct :test #'string=)))
    (is (equal "http://127.0.0.1:6152/" (after "--proxy" proxied)))
    (is (null (member "--noproxy" proxied :test #'string=)))
    (is (equal "30" (after "--max-time" proxied)))
    (is (equal "=http,https" (after "--proto" direct)))
    (is (equal "=http,https" (after "--proto-redir" direct)))
    (is (equal "/tmp/a" (after "--output" direct)))
    (is (member "--compressed" direct :test #'string=))
    ;; The URL comes last, as --url's, whatever it begins with.
    (is (equal '("--url" "https://elpa.gnu.org/packages/archive-contents") (last direct 2)))))

(deftest fetch-downloads-into-the-file ()
  (with-directory (directory)
    (let ((source (write-file (path directory "archive-contents") "(1" " (ack . [(1 0) nil \"A\" tar]))"))
          (target (path directory "fetched")))
      (with-globals ((lispm-kernel::*fetch-protocols* "=file"))
        (with-kernel (kernel collector)
          (send kernel (format nil "(submit 1 fetch (:url ~S :file ~S))" (file-url source) target))
          (is (equal '(:done 1 :success 33) (done-of 1 (answered collector 1))))
          (is (equal (uiop:read-file-string (sb-ext:parse-native-namestring source))
                     (uiop:read-file-string (sb-ext:parse-native-namestring target)))))))))

(deftest fetch-fails-with-what-curl-said ()
  (with-directory (directory)
    (let ((target (write-file (path directory "fetched") "stale")))
      (with-kernel (kernel collector)
        ;; Only http and https are fetched.
        (send kernel (format nil "(submit 1 fetch (:url ~S :file ~S))"
                             (file-url (path directory "nowhere")) target))
        (let ((done (done-of 1 (answered collector 1))))
          (is (eq :failed (third done)))
          (is (search "curl:" (fourth done))))
        (is (not (there-p target))))
      (with-globals ((lispm-kernel::*fetch-protocols* "=file"))
        (with-kernel (kernel collector)
          (send kernel (format nil "(submit 2 fetch (:url ~S :file ~S))"
                               (file-url (path directory "nowhere")) (path directory "fetched"))
                "(submit 3 fetch (:url 7))")
          (let ((messages (answered collector 2 3)))
            (is (eq :failed (third (done-of 2 messages))))
            (is (search "curl:" (fourth (done-of 2 messages))))
            (is (eq :failed (third (done-of 3 messages)))))
          (is (not (there-p (path directory "fetched")))))))))

(deftest fetch-cancelled-stops-curl ()
  (with-directory (directory)
    ;; curl waits to open a pipe nobody writes to, until it is stopped.
    (let ((pipe (path directory "pipe"))
          (target (path directory "fetched")))
      (sb-posix:mkfifo pipe #o600)
      (with-globals ((lispm-kernel::*fetch-protocols* "=file"))
        (with-kernel (kernel collector)
          (send kernel (format nil "(submit 1 fetch (:url ~S :file ~S))" (file-url pipe) target))
          (sleep 0.3)
          (is (null (done-of 1 (messages collector))))
          (let ((started (get-internal-real-time)))
            (send kernel "(cancel 1)")
            (is (equal '(:done 1 :cancelled nil) (done-of 1 (answered collector 1))))
            (is (< (- (get-internal-real-time) started) internal-time-units-per-second)))
          (is (not (there-p target))))))))
