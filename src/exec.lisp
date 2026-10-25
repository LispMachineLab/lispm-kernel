;;;; exec.lisp --- Programs Emacs does not wait on

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

;;; Emacs that runs a program forks itself, a large process, and reads
;;; what the program prints on its own thread; waiting for it, as
;;; `call-process' and `process-lines' do, it does nothing else.  The
;;; exec job runs the program instead, in the kernel:
;;;
;;;   Emacs  (submit 4 exec (:program "/bin/ps" :args ("-axo" "pid=")
;;;                          :cwd "/Users/me/" :env ("PATH=/bin" ...)))
;;;   kernel (chunk 4 "  1\n  97\n") ...  (done 4 success (:exit 0 :stderr ""))
;;;
;;; PROGRAM is a file, as Emacs found it in `exec-path'; it runs with
;;; ARGS in the directory CWD, with ENV, the whole of its environment as
;;; "NAME=VALUE" strings, else the kernel's, reading STDIN, a string,
;;; when given, else nothing.  What it prints on its standard output
;;; comes as chunks, strings, as it comes; the result says how it ended,
;;; (:exit CODE :stderr TEXT), or (:signal NUMBER :stderr TEXT) when a
;;; signal ended it, TEXT the last of what it printed on its standard
;;; error.  Both are read as UTF-8.  A program that cannot be started
;;; fails the request, saying why; one that takes longer than TIMEOUT
;;; seconds, when given, is stopped and fails it.  Cancelling the request
;;; stops it.  Stopping a program stops its process group, the programs
;;; it started with it: SIGTERM first, SIGKILL a second later.

(in-package #:lispm-kernel)

(defparameter *exec-read-octets* 65536
  "Octets of a program's output read at a time, at most.")

(defparameter *exec-stderr-limit* 65536
  "Octets of a program's standard error kept, the last.")

(defparameter *exec-poll-seconds* 0.005
  "Seconds the job waits for output before it looks again whether it was
cancelled or the program exited.")

(defparameter *exec-kill-seconds* 1
  "Seconds a program stopped with SIGTERM has to exit before SIGKILL.")

(defun complete-utf-8-end (octets end)
  "Return the end of the whole UTF-8 sequences among OCTETS below END:
END, or where a sequence begins that END cuts short."
  (loop for index from (1- end) downto (max 0 (- end 3))
        for octet = (aref octets index)
        do (cond ((< octet #x80) (return end))
                 ((>= octet #xC0)
                  (let ((length (cond ((>= octet #xF0) 4) ((>= octet #xE0) 3) (t 2))))
                    (return (if (> (+ index length) end) index end)))))
        finally (return end)))

(defun utf-8-text (octets start end)
  "Return OCTETS from START to END as text, read as UTF-8."
  (sb-ext:octets-to-string octets :start start :end end
                                  :external-format '(:utf-8 :replacement #\REPLACEMENT_CHARACTER)))

(defun read-some (fd buffer start timeout)
  "Read what FD has into BUFFER from START, waiting at most TIMEOUT
seconds; return how many octets came, 0 at its end, or nil when none did."
  (when (sb-sys:wait-until-fd-usable fd :input timeout nil)
    (loop
      (multiple-value-bind (count errno)
          (sb-sys:with-pinned-objects (buffer)
            (sb-unix:unix-read fd (sb-sys:sap+ (sb-sys:vector-sap buffer) start)
                               (- (length buffer) start)))
        (cond (count (return count))
              ((/= errno sb-unix:eintr)
               (error "Reading the program's output failed: ~A" (sb-int:strerror errno))))))))

(defun stop-process (process)
  "Stop PROCESS and the programs of its process group, and wait for it:
SIGTERM, then SIGKILL after `*exec-kill-seconds*'."
  (when (sb-ext:process-alive-p process)
    (sb-ext:process-kill process sb-posix:sigterm :process-group)
    (let ((deadline (+ (get-internal-real-time) (* *exec-kill-seconds* internal-time-units-per-second))))
      (loop while (and (sb-ext:process-alive-p process) (< (get-internal-real-time) deadline))
            do (sleep 0.005)))
    (when (sb-ext:process-alive-p process)
      (sb-ext:process-kill process sb-posix:sigkill :process-group))
    (sb-ext:process-wait process)))

(defun feed (process stdin)
  "Write STDIN to PROCESS's standard input on a thread of its own, then
close it; return the thread.  A program that does not read it all is
no error."
  (let ((stream (sb-ext:process-input process)))
    (sb-thread:make-thread
     (lambda ()
       (ignore-errors (write-string stdin stream) (finish-output stream))
       (ignore-errors (close stream)))
     :name "lispm-kernel exec input")))

(defun exec-environment (env)
  "Return ENV as run-program takes an environment, or the kernel's own for nil."
  (if env
      (progn (check-type env list)
             (dolist (entry env env)
               (unless (and (stringp entry) (find #\= entry))
                 (error "An environment entry is NAME=VALUE, not ~S" entry))))
      (sb-ext:posix-environ)))

(define-job (exec :class :io) (input)
  "Run PROGRAM with ARGS in CWD, its environment ENV, reading STDIN, at most
TIMEOUT seconds; emit its standard output and return how it ended.
INPUT is a plist of them."
  (destructuring-bind (&key program args cwd env stdin timeout) input
    (check-type program string)
    (check-type args list)
    (dolist (arg args) (check-type arg string))
    (check-type cwd (or null string))
    (check-type stdin (or null string))
    (check-type timeout (or null (integer 1 86400)))
    (unless (and (plusp (length program)) (char= (char program 0) #\/))
      (error "The program to run is a file, not ~S" program))
    (let* ((process (sb-ext:run-program program args
                                        :search nil :wait nil :directory cwd
                                        :environment (exec-environment env)
                                        :input (if stdin :stream nil) :output :stream :error :stream
                                        :external-format '(:utf-8 :replacement #\?)))
           (feeder (and stdin (feed process stdin)))
           (deadline (and timeout (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
           (output (make-array (+ *exec-read-octets* 3) :element-type '(unsigned-byte 8)))
           (errors (make-array 4096 :element-type '(unsigned-byte 8)))
           (kept (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
           (output-fd (sb-sys:fd-stream-fd (sb-ext:process-output process)))
           (error-fd (sb-sys:fd-stream-fd (sb-ext:process-error process)))
           (carried 0))
      (unwind-protect
           (flet ((take-output (timeout)
                    ;; Emit what came, keeping a UTF-8 sequence cut short for
                    ;; the next; return nil at the end, :none when nothing came.
                    (let ((count (read-some output-fd output carried timeout)))
                      (cond ((null count) :none)
                            ((zerop count)
                             (when (plusp carried)
                               (emit (utf-8-text output 0 carried)))
                             nil)
                            (t (let* ((end (+ carried count))
                                      (whole (complete-utf-8-end output end)))
                                 (when (plusp whole)
                                   (emit (utf-8-text output 0 whole)))
                                 (replace output output :start2 whole :end2 end)
                                 (setf carried (- end whole))
                                 t)))))
                  (take-errors ()
                    ;; Keep the last of what came; return nil at the end.
                    (let ((count (read-some error-fd errors 0 0)))
                      (cond ((null count) :none)
                            ((zerop count) nil)
                            (t (loop for index below count
                                     do (vector-push-extend (aref errors index) kept))
                               (when (> (length kept) (* 2 *exec-stderr-limit*))
                                 (let ((cut (- (length kept) *exec-stderr-limit*)))
                                   (replace kept kept :start2 cut)
                                   (setf (fill-pointer kept) *exec-stderr-limit*)))
                               t)))))
             (let ((output-open t) (errors-open t))
               ;; Until both ends are reached, or the program exited and
               ;; printed nothing more: what it started may hold them.
               (loop while (or output-open errors-open)
                     do (checkpoint)
                        (when (and deadline (> (get-internal-real-time) deadline))
                          (error "~A did not finish in ~D seconds" program timeout))
                        (let* ((alive (sb-ext:process-alive-p process))
                               (wait (if alive *exec-poll-seconds* 0))
                               (out (if output-open (take-output wait) :none))
                               (err (if errors-open (take-errors) :none)))
                          (unless out (setf output-open nil))
                          (unless err (setf errors-open nil))
                          (when (and (eq out :none) (eq err :none))
                            (cond ((not alive) (return))
                                  ((not output-open) (sleep *exec-poll-seconds*)))))))
             (loop while (sb-ext:process-alive-p process)
                   do (checkpoint)
                      (when (and deadline (> (get-internal-real-time) deadline))
                        (error "~A did not finish in ~D seconds" program timeout))
                      (sleep *exec-poll-seconds*))
             (let ((stderr (let ((start (max 0 (- (length kept) *exec-stderr-limit*))))
                             (utf-8-text kept start (length kept)))))
               (if (eq (sb-ext:process-status process) :signaled)
                   (list :signal (sb-ext:process-exit-code process) :stderr stderr)
                   (list :exit (sb-ext:process-exit-code process) :stderr stderr))))
        (stop-process process)
        (when feeder
          (sb-thread:join-thread feeder :default nil :timeout 5))
        (sb-ext:process-close process)))))
