;;;; main.lisp --- The kernel as a program Emacs runs

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

;;; The program reads Emacs's messages from its standard input, one per
;;; line, and writes its own to its standard output.  It says hello
;;; first:
;;;
;;;   (hello :protocol 1 :pid PID :lisp "SBCL 2.6.9" :workers (:cpu 2 :io 4) ...)
;;;
;;; It ends when its standard input does, when Emacs closes the pipe or
;;; goes away, or when Emacs sends (quit), without waiting for the work
;;; it was doing.

(in-package #:lispm-kernel)

(defparameter *cpu-workers* 2
  "Threads running jobs of the class :cpu.")

(defparameter *io-workers* 4
  "Threads running jobs of the class :io.")

(defun hello ()
  (list 'hello
        :protocol +protocol+
        :pid (sb-posix:getpid)
        :lisp (format nil "~A ~A" (lisp-implementation-type) (lisp-implementation-version))
        :machine (string-downcase (machine-type))
        :workers (list :cpu *cpu-workers* :io *io-workers*)
        :nanoseconds (and (lispm-kernel/files:native-stat-p) t)
        :jobs (sort (loop for name being the hash-keys of *jobs* collect name) #'string<)))

(defun stream-sink (stream)
  "Return a sink writing messages to STREAM, one per line.  When Emacs no
longer reads them, the kernel ends."
  (lambda (messages)
    (handler-case
        (progn
          (dolist (message messages)
            (write-string message stream)
            (write-char #\Newline stream))
          (finish-output stream))
      (error ()
        (sb-ext:exit :code 0 :abort t)))))

(defun main ()
  "Run the kernel for Emacs over standard input and output."
  (sb-ext:disable-debugger)
  (when (member "--version" (rest sb-ext:*posix-argv*) :test #'string=)
    (format t "lispm-kernel, protocol ~D, ~A ~A~%"
            +protocol+ (lisp-implementation-type) (lisp-implementation-version))
    (finish-output)
    (sb-ext:exit :code 0))
  (setf (sb-ext:bytes-consed-between-gcs) (* 16 1024 1024))
  (let* ((input (sb-sys:make-fd-stream 0 :input t :buffering :full :name "Emacs"
                                         :external-format '(:utf-8 :replacement #\REPLACEMENT_CHARACTER)))
         (output (sb-sys:make-fd-stream 1 :output t :buffering :full :name "Emacs"
                                          :external-format :utf-8))
         (kernel (start-kernel (stream-sink output)
                               :cpu-workers *cpu-workers* :io-workers *io-workers*)))
    (setf *kernel* kernel)
    (outbox-put (kernel-outbox kernel) (message-string (hello)))
    (handler-case
        (loop for line = (read-line input nil nil)
              while line
              until (eq (handle-line kernel line) :quit))
      (error (condition)
        (format *error-output* "lispm-kernel: ~A~%" (condition-text condition))))
    (sb-ext:exit :code 0 :abort t)))
