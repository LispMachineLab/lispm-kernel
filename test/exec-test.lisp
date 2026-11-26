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

(deftest http-stream-feeds-headers-and-body-and-cleans-temp-file ()
  (with-directory (directory)
    (let ((fake-curl (write-file (path directory "fake-curl")
                                 "#!/bin/sh"
                                 "cfg=$(cat)"
                                 "for arg in \"$@\"; do"
                                 "  case \"$arg\" in"
                                 "    @*) file=${arg#@} ;;"
                                 "  esac"
                                 "done"
                                 "printf 'CFG:%s|BODY:%s|FILE:%s\\n' \"$cfg\" \"$(cat \"$file\")\" \"$file\""
                                 "printf '\\n__LISPM_HTTP_STATUS__:200\\n'")))
      (sb-posix:chmod fake-curl #o755)
      (with-kernel (kernel collector)
        (send kernel
              (message-string
               `(submit 1 http-stream
                        (:url "https://api.example.com/v1/messages"
                         :headers ("x-api-key: secret\"key" "content-type: application/json")
                         :body "{\"model\":\"demo\"}"
                         :curl ,fake-curl))))
        (let* ((messages (answered collector 1))
               (out (output-of 1 messages))
               (done (done-of 1 messages))
               (file-pos (search "|FILE:" out))
               (status-pos (search "__LISPM_HTTP_STATUS__:200" out))
               (temp-path (and file-pos status-pos
                               (string-trim '(#\Newline #\Return)
                                            (subseq out (+ file-pos 6) status-pos)))))
          (is (equal '(:done 1 :success (:exit 0 :stderr "")) done))
          (is (search "header = \"x-api-key: secret\\\"key\"" out))
          (is (search "|BODY:{\"model\":\"demo\"}|" out))
          (is status-pos)
          ;; Temporary request body file is removed once curl finishes.
          (is (and temp-path (not (probe-file (sb-ext:parse-native-namestring temp-path))))))))))

(deftest exec-searches-path-and-merges-environment-when-asked ()
  (with-kernel (kernel collector)
    (send kernel
          (message-string
           '(submit 1 exec (:program "sh"
                            :args ("-c" "printf '%s|%s' \"$LISPM_TEST_OVERRIDE\" \"${PATH:+present}\"")
                            :env ("LISPM_TEST_OVERRIDE=custom")
                            :env-inherit t
                            :search t))))
    (let ((messages (answered collector 1)))
      (is (equal '(:done 1 :success (:exit 0 :stderr "")) (done-of 1 messages)))
      (is (equal "custom|present" (output-of 1 messages))))))

(deftest stop-kernel-stops-running-exec-process-groups ()
  (let* ((collector (make-collector))
         (kernel (lispm-kernel:start-kernel (collector-sink collector))))
    (unwind-protect
         (progn
           (send kernel (shell 1 "sleep 30 & echo $!; wait"))
           (let ((pid (parse-integer
                       (output-of 1 (await collector
                                           (lambda (messages)
                                             (find #\Newline (output-of 1 messages))))))))
             (is (process-there-p pid))
             (lispm-kernel:stop-kernel kernel :timeout 2)
             (sleep 0.1)
             (is (not (process-there-p pid)))))
      (ignore-errors (lispm-kernel:stop-kernel kernel :timeout 1)))))

(defun exec-owned (id owner program args &rest keys)
  "Return the submission of request ID for OWNER running PROGRAM with ARGS and KEYS."
  (message-string `(submit ,id exec (:program ,program :args ,args ,@keys) :owner ,owner)))

(defun shell-owned (id owner script &rest keys)
  "Return the submission of shell request ID for OWNER running SCRIPT and KEYS."
  (apply #'exec-owned id owner "/bin/sh" (list "-c" script) keys))

(deftest exec-reactor-high-concurrency-without-io-starvation ()
  (with-directory (directory)
    (let ((fake-curl (write-file (path directory "fake-curl")
                                 "#!/bin/sh"
                                 "cat >/dev/null"
                                 "sleep 0.3"
                                 "printf 'stream-ok\\n'"
                                 "printf '\\n__LISPM_HTTP_STATUS__:200\\n'")))
      (sb-posix:chmod fake-curl #o755)
      (with-kernel (kernel collector :io-workers 2 :reactor-slots 128)
        (let ((started (get-internal-real-time))
              (ids (loop for id from 1 to 52 collect id)))
          (loop for id from 1 to 32
                do (send kernel
                         (message-string
                          `(submit ,id http-stream
                                   (:url "https://api.example.com/v1/stream"
                                    :headers ("x-test: 1")
                                    :body "payload"
                                    :curl ,fake-curl)
                                   :owner ,(1+ (mod id 4))))))
          (loop for id from 33 to 48
                do (send kernel
                         (shell-owned id (1+ (mod id 4))
                                      (format nil "sleep 0.3; printf 'exec-~D'" id))))
          (loop for id from 49 to 52
                do (send kernel
                         (message-string `(submit ,id wait (:milliseconds 250) :owner 99))))
          (let* ((messages (apply #'answered collector ids))
                 (elapsed (/ (- (get-internal-real-time) started)
                             (float internal-time-units-per-second))))
            (is (< elapsed 4.0))
            (loop for id from 1 to 32
                  do (is (equal '(:exit 0 :stderr "") (fourth (done-of id messages))))
                     (is (search "stream-ok" (output-of id messages))))
            (loop for id from 33 to 48
                  do (is (equal '(:exit 0 :stderr "") (fourth (done-of id messages))))
                     (is (equal (format nil "exec-~D" id) (output-of id messages))))
            (loop for id from 49 to 52
                  do (is (eq :success (third (done-of id messages)))))
            (let ((stats (lispm-kernel:kernel-stats kernel)))
              (is (= 0 (getf stats :requests)))
              (is (= 0 (getf stats :reactor-active))))))))))

(deftest exec-reactor-per-owner-quota-and-sibling-isolation ()
  (with-globals ((lispm-kernel::*max-requests* 32)
                 (lispm-kernel::*max-requests-per-owner* 3))
    (with-kernel (kernel collector :io-workers 2)
      (send kernel
            (shell-owned 1 101 "sleep 10")
            (shell-owned 2 101 "sleep 10")
            (shell-owned 3 101 "sleep 10")
            (shell-owned 4 101 "printf blocked")
            (shell-owned 5 102 "printf sibling-ok"))
      (let ((messages (answered collector 4 5)))
        (is (equal '(:done 4 :rejected :capacity) (done-of 4 messages)))
        (is (equal '(:done 5 :success (:exit 0 :stderr "")) (done-of 5 messages)))
        (is (equal "sibling-ok" (output-of 5 messages))))
      (send kernel "(cancel 1)" "(cancel 2)" "(cancel 3)")
      (answered collector 1 2 3)
      (is (= 0 (getf (lispm-kernel:kernel-stats kernel) :reactor-active))))))

(deftest exec-reactor-per-stream-backpressure-and-resume ()
  (with-globals ((lispm-kernel::*exec-read-octets* 128)
                 (lispm-kernel::*exec-stream-credit* 512)
                 (lispm-kernel::*outbox-limit* 65536))
    (with-kernel (kernel collector :io-workers 2)
      ;; Phase 1: stalling the consumer stops the firehose at its per-stream budget
      ;; without starving a sibling or delaying cancellation.
      (setf (collector-stalled collector) t)
      (send kernel
            (shell-owned 1 201 "yes abcdefghijklmnop | head -c 50000")
            (shell-owned 2 202 "printf sibling-live"))
      (sleep 0.12)
      (let ((waiting (lispm-kernel::outbox-waiting (lispm-kernel::kernel-outbox kernel))))
        (is (<= waiting 2048)))
      (send kernel "(cancel 1)")
      (lispm-kernel:kernel-stats kernel)
      (setf (collector-stalled collector) nil)
      (let ((messages (answered collector 1 2)))
        (is (equal '(:done 1 :cancelled nil) (done-of 1 messages)))
        (is (equal '(:exit 0 :stderr "") (fourth (done-of 2 messages))))
        (is (equal "sibling-live" (output-of 2 messages))))
      ;; Phase 2: full resume under active per-stream credit delivers all octets intact.
      (send kernel (shell-owned 3 201 "head -c 32768 /dev/zero | tr '\\0' x"))
      (let* ((messages (answered collector 3))
             (output (output-of 3 messages)))
        (is (equal '(:exit 0 :stderr "") (fourth (done-of 3 messages))))
        (is (= 32768 (length output)))
        (is (every (lambda (ch) (char= ch #\x)) output))))))

(deftest exec-reactor-mixed-cancel-timeout-and-cleanup ()
  (with-kernel (kernel collector :io-workers 2)
    (let ((started (get-internal-real-time)))
      (dotimes (i 4)
        (send kernel (shell-owned (+ 10 i) 301 "sleep 30 & echo $!; wait")))
      (let* ((msgs (await collector
                          (lambda (ms)
                            (every (lambda (id) (find #\Newline (output-of id ms)))
                                   '(10 11 12 13)))))
             (pids (loop for id from 10 to 13
                         collect (parse-integer (output-of id msgs)))))
        (dolist (pid pids)
          (is (process-there-p pid)))
        (send kernel
              (exec-owned 20 302 "/bin/sleep" '("30") :timeout 1)
              (exec-owned 21 302 "/bin/sleep" '("30") :timeout 1)
              (shell-owned 30 303 "printf ok-30")
              (shell-owned 31 303 "printf ok-31"))
        (send kernel "(cancel 10)" "(cancel 11)" "(cancel 12)" "(cancel 13)")
        (let ((all (answered collector 10 11 12 13 20 21 30 31)))
          (dolist (id '(10 11 12 13))
            (is (equal `(:done ,id :cancelled nil) (done-of id all))))
          (dolist (id '(20 21))
            (is (eq :failed (third (done-of id all))))
            (is (search "did not finish" (fourth (done-of id all)))))
          (dolist (id '(30 31))
            (is (equal (format nil "ok-~D" id) (output-of id all)))))
        (sleep 0.1)
        (dolist (pid pids)
          (is (not (process-there-p pid))))
        (is (< (- (get-internal-real-time) started) (* 4 internal-time-units-per-second)))
        (is (= 0 (getf (lispm-kernel:kernel-stats kernel) :reactor-active)))))))

(deftest exec-reactor-parallel-shutdown-of-stubborn-processes ()
  (with-globals ((lispm-kernel::*exec-kill-seconds* 1))
    (let* ((collector (make-collector))
           (kernel (lispm-kernel:start-kernel (collector-sink collector) :io-workers 1)))
      (unwind-protect
           (progn
             (loop for id from 1 to 4
                   do (send kernel (shell id "trap '' TERM; printf 'ready\\n'; sleep 30")))
             (await collector
                    (lambda (msgs)
                      (every (lambda (id) (search "ready" (output-of id msgs)))
                             '(1 2 3 4))))
             (let ((started (get-internal-real-time)))
               (lispm-kernel:stop-kernel kernel :timeout 5)
               (let ((elapsed (/ (- (get-internal-real-time) started)
                                 (float internal-time-units-per-second))))
                 (is (< elapsed 2.5))))
             (let ((msgs (messages collector)))
               (loop for id from 1 to 4
                     do (is (equal `(:done ,id :cancelled nil) (done-of id msgs))))))
        (ignore-errors (lispm-kernel:stop-kernel kernel :timeout 1))))))
