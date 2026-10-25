;;;; exec-test.lisp --- Tests of the programs the kernel runs

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

;;; The programs are /bin/sh scripts and the like, which every Unix has.

(in-package #:lispm-kernel/test)

(defun exec-line (id program args &rest keys)
  "Return the submission of request ID running PROGRAM with ARGS and KEYS."
  (message-string `(submit ,id exec (:program ,program :args ,args ,@keys))))

(defun output-of (id messages)
  "Return what request ID's chunks in MESSAGES hold, joined."
  (apply #'concatenate 'string
         (loop for message in messages
               when (and (eq (first message) :chunk) (eql (second message) id))
                 collect (third message))))

(defun shell (id script &rest keys)
  (apply #'exec-line id "/bin/sh" (list "-c" script) keys))

(defun process-there-p (pid)
  (zerop (sb-unix:unix-kill pid 0)))

(deftest exec-utf-8-ends ()
  (let ((lambda-and-han (octets (chars #x3BB #x4E2D))))
    ;; U+03BB is 2 octets, U+4E2D 3.
    (is (= 5 (complete-utf-8-end* lambda-and-han 5)))
    (is (= 2 (complete-utf-8-end* lambda-and-han 4)))
    (is (= 2 (complete-utf-8-end* lambda-and-han 3)))
    (is (= 2 (complete-utf-8-end* lambda-and-han 2)))
    (is (= 0 (complete-utf-8-end* lambda-and-han 1)))
    (is (= 0 (complete-utf-8-end* lambda-and-han 0)))
    (is (= 3 (complete-utf-8-end* (octets "abc") 3)))))

(defun complete-utf-8-end* (octets end)
  (lispm-kernel::complete-utf-8-end octets end))

(deftest exec-runs-a-program ()
  (with-kernel (kernel collector)
    (send kernel (shell 1 "printf 'a\\nb\\n'; printf oops >&2; exit 3"))
    (let ((messages (answered collector 1)))
      (is (equal "a
b
" (output-of 1 messages)))
      (is (equal '(:done 1 :success (:exit 3 :stderr "oops")) (done-of 1 messages))))
    (is (member :exec (getf (rest (lispm-kernel::hello)) :jobs)))))

(deftest exec-gives-directory-environment-and-input ()
  (with-directory (directory)
    (with-kernel (kernel collector)
      (send kernel (shell 1 "pwd -P; echo \"$FOO\"; cat"
                          :cwd directory :env '("FOO=bar λ" "PATH=/usr/bin:/bin")
                          :stdin (format nil "piped ~A~%" (chars #x4E2D))))
      (let ((messages (answered collector 1)))
        (is (equal (format nil "~A~%bar ~A~%piped ~A~%"
                           (string-right-trim "/" (namestring (truename (sb-ext:parse-native-namestring
                                                                         (concatenate 'string directory "/")))))
                           (chars #x3BB) (chars #x4E2D))
                   (output-of 1 messages)))
        (is (equal '(:exit 0 :stderr "") (fourth (done-of 1 messages))))))))

(deftest exec-reads-output-cut-mid-character ()
  (with-globals ((lispm-kernel::*exec-read-octets* 1))
    (with-kernel (kernel collector)
      (send kernel (shell 1 (format nil "printf '~A~A~A'" (chars #x3BB) (chars #x4E2D) (chars #x1F600))))
      (let ((messages (answered collector 1)))
        (is (equal (chars #x3BB #x4E2D #x1F600) (output-of 1 messages)))))))

(deftest exec-streams-much-output ()
  (with-kernel (kernel collector)
    (send kernel (shell 1 "head -c 300000 /dev/zero | tr '\\0' a"))
    (let* ((messages (answered collector 1))
           (output (output-of 1 messages)))
      (is (= 300000 (length output)))
      (is (every (lambda (character) (char= character #\a)) output))
      (is (< 1 (count-if (lambda (message) (eq (first message) :chunk)) messages))))))

(deftest exec-says-a-signal-ended-it ()
  (with-kernel (kernel collector)
    (send kernel (shell 1 "kill -TERM $$"))
    (is (equal '(:done 1 :success (:signal 15 :stderr ""))
               (done-of 1 (answered collector 1))))))

(deftest exec-fails-what-cannot-run ()
  (with-kernel (kernel collector)
    (send kernel
          (exec-line 1 "/nonexistent/program" '())
          (exec-line 2 "sh" '("-c" "true"))
          (exec-line 3 "/bin/sh" '("-c" "true") :cwd "/nonexistent/directory")
          (exec-line 4 "/bin/sh" '("-c" "true") :env '("NOEQUALS"))
          (exec-line 5 "/bin/sh" '(7)))
    (let ((messages (answered collector 1 2 3 4 5)))
      (dolist (id '(1 2 3 4 5))
        (is (eq :failed (third (done-of id messages)))))
      (is (search "file" (fourth (done-of 2 messages)))))))

(deftest exec-ends-with-the-program-not-what-it-left ()
  ;; The sleep holds the output open long after the shell exited.
  (with-kernel (kernel collector)
    (let ((started (get-internal-real-time)))
      (send kernel (shell 1 "echo hi; sleep 3 &"))
      (let ((messages (answered collector 1)))
        (is (equal (format nil "hi~%") (output-of 1 messages)))
        (is (equal '(:exit 0 :stderr "") (fourth (done-of 1 messages)))))
      (is (< (- (get-internal-real-time) started) (* 2 internal-time-units-per-second))))))

(deftest exec-input-not-read-is-no-error ()
  (with-kernel (kernel collector)
    (send kernel (exec-line 1 "/usr/bin/true" '() :stdin (make-string (* 1024 1024) :initial-element #\x)))
    (is (equal '(:done 1 :success (:exit 0 :stderr ""))
               (done-of 1 (answered collector 1))))))

(deftest exec-cancelled-stops-its-process-group ()
  (with-kernel (kernel collector)
    (send kernel (shell 1 "sleep 30 & echo $!; wait"))
    (let* ((pid (parse-integer (output-of 1 (await collector (lambda (messages)
                                                                (find #\Newline (output-of 1 messages))))))))
      (is (process-there-p pid))
      (let ((started (get-internal-real-time)))
        (send kernel "(cancel 1)")
        (is (equal '(:done 1 :cancelled nil) (done-of 1 (answered collector 1))))
        (is (< (- (get-internal-real-time) started) (* 2 internal-time-units-per-second))))
      (sleep 0.1)
      (is (not (process-there-p pid))))))

(deftest exec-stops-a-program-past-its-timeout ()
  (with-kernel (kernel collector)
    (let ((started (get-internal-real-time)))
      (send kernel (exec-line 1 "/bin/sleep" '("30") :timeout 1))
      (let ((done (done-of 1 (answered collector 1))))
        (is (eq :failed (third done)))
        (is (search "did not finish" (fourth done))))
      (is (< (- (get-internal-real-time) started) (* 3 internal-time-units-per-second))))))

(deftest exec-keeps-the-last-of-standard-error ()
  (with-globals ((lispm-kernel::*exec-stderr-limit* 10))
    (with-kernel (kernel collector)
      (send kernel (shell 1 "i=0; while [ $i -lt 100 ]; do printf x >&2; i=$((i+1)); done; printf END >&2"))
      (let ((result (fourth (done-of 1 (answered collector 1)))))
        (is (equal "xxxxxxxEND" (getf result :stderr)))))))
