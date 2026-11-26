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

(defparameter *subworkers* 3
  "Persistent subworker threads shared by data-parallel batches.")

(defparameter *cli-integer-options*
  '(("--cpu-workers" :cpu-workers 1 64)
    ("--io-workers" :io-workers 1 64)
    ("--subworkers" :subworkers 0 64)
    ("--max-requests" :max-requests 1 65536)
    ("--max-requests-per-owner" :max-requests-per-owner 1 65536)
    ("--max-reactor-slots" :max-reactor-slots 1 16384)
    ("--stream-credit" :stream-credit 1024 67108864))
  "Supported integer CLI option specifications: (FLAG KEY MIN MAX).")

(defun parse-bounded-integer (flag text min max)
  "Parse TEXT as an integer in [MIN, MAX] for CLI FLAG, or signal `message-error'."
  (let ((value (and (plusp (length text))
                    (every #'digit-char-p text)
                    (handler-case (parse-integer text)
                      (parse-error () nil)))))
    (unless (and (integerp value) (<= min value max))
      (message-error "Option ~A requires an integer in [~D, ~D], not ~S" flag min max text))
    value))

(defun parse-cli-options (argv)
  "Parse command-line options ARGV.
Return `:version' when `--version' is passed, or a keyword plist of options."
  (let ((options nil)
        (rest argv))
    (loop while rest
          for flag = (pop rest)
          do (cond
               ((string= flag "--version")
                (return-from parse-cli-options :version))
               ((string= flag "--socket")
                (unless rest
                  (message-error "Option ~A requires a path argument" flag))
                (let ((path (pop rest)))
                  (unless (plusp (length path))
                    (message-error "Option ~A requires a non-empty path" flag))
                  (setf (getf options :socket) path)))
               (t
                (let ((spec (assoc flag *cli-integer-options* :test #'string=)))
                  (unless spec
                    (message-error "Unknown option ~S" flag))
                  (unless rest
                    (message-error "Option ~A requires an integer argument" flag))
                  (destructuring-bind (_ key min max) spec
                    (declare (ignore _))
                    (setf (getf options key)
                          (parse-bounded-integer flag (pop rest) min max)))))))
    options))

(defun hello ()
  (list 'hello
        :protocol +protocol+
        :pid (sb-posix:getpid)
        :lisp (format nil "~A ~A" (lisp-implementation-type) (lisp-implementation-version))
        :machine (string-downcase (machine-type))
        :workers (list :cpu *cpu-workers* :io *io-workers* :reactor *max-reactor-slots*)
        :limits (list :requests *max-requests*
                      :per-owner *max-requests-per-owner*
                      :reactor *max-reactor-slots*
                      :stream-credit *exec-stream-credit*)
        :nanoseconds (and (lispm-kernel/files:native-stat-p) t)
        :features '(:agent-actors :sse-decode :effect-rpc :socket-reconnect)
        :jobs (sort (loop for name being the hash-keys of *jobs* collect name) #'string<)))

(declaim (ftype (function () *) main))

(defun stream-sink (stream)
  "Return a sink writing messages to STREAM, one per line.  When Emacs no
longer reads them, the kernel stops its work and ends."
  (lambda (messages)
    (handler-case
        (progn
          (dolist (message messages)
            (write-string message stream)
            (write-char #\Newline stream))
          (finish-output stream))
      (stream-error ()
        (handler-case
            (when *kernel*
              (stop-kernel *kernel* :timeout 2))
          (serious-condition () nil))
        (sb-ext:exit :code 0 :abort t)))))

;;;; Reconnectable Unix domain socket daemon transport

(defstruct (socket-writer-target (:constructor make-socket-writer-target ()) (:copier nil))
  "Lock-free CAS holder for the currently connected client socket stream."
  (stream nil))

(defun socket-sink (target)
  "Return a `P_writer' sink writing to TARGET's connected client, if any.
When Emacs is detached, messages are dropped without halting active actors."
  (lambda (messages)
    (let ((stream (socket-writer-target-stream target)))
      (when stream
        (handler-case
            (progn
              (dolist (message messages)
                (write-string message stream)
                (write-char #\Newline stream))
              (finish-output stream))
          (serious-condition ()
            (sb-ext:compare-and-swap (socket-writer-target-stream target) stream nil)))))))

(defun unlink-socket-quietly (path)
  "Remove Unix domain socket PATH if present, ignoring errors."
  (ignore-errors (sb-posix:unlink path)))

(defun run-socket-server (socket-path &key cpu-workers io-workers subworkers reactor-slots on-ready)
  "Serve the CSP kernel over Unix domain socket SOCKET-PATH across reconnects.
Client EOF detaches Emacs while keeping all running `P_agents' alive; `(quit)'
shuts down both kernel and socket listener.  ON-READY, when non-nil, is called
with SOCKET-PATH once bound and listening."
  (unlink-socket-quietly socket-path)
  (let* ((server (make-instance 'sb-bsd-sockets:local-socket :type :stream))
         (target (make-socket-writer-target))
         (kernel nil)
         (quit-requested nil))
    (unwind-protect
         (progn
           (sb-bsd-sockets:socket-bind server socket-path)
           (sb-posix:chmod socket-path #o600)
           (sb-bsd-sockets:socket-listen server 16)
           (setf kernel (start-kernel (socket-sink target)
                                      :cpu-workers (or cpu-workers *cpu-workers*)
                                      :io-workers (or io-workers *io-workers*)
                                      :subworkers (or subworkers *subworkers*)
                                      :reactor-slots (or reactor-slots *max-reactor-slots*)))
           (when on-ready
             (funcall on-ready socket-path))
           (loop until quit-requested
                 do (let ((client (handler-case (sb-bsd-sockets:socket-accept server)
                                    (serious-condition () nil))))
                      (when client
                        (let ((client-stream nil))
                          (unwind-protect
                               (progn
                                 (setf client-stream
                                       (sb-bsd-sockets:socket-make-stream
                                        client
                                        :input t :output t
                                        :buffering :full
                                        :element-type 'character
                                        :external-format '(:utf-8 :replacement #\REPLACEMENT_CHARACTER)))
                                 (write-line (message-string (hello)) client-stream)
                                 (finish-output client-stream)
                                 (setf (socket-writer-target-stream target) client-stream)
                                 (handler-case
                                     (loop for line = (read-line client-stream nil nil)
                                           while line
                                           when (eq (handle-line kernel line) :quit)
                                             do (setf quit-requested t)
                                                (return))
                                   (serious-condition () nil)))
                            (sb-ext:compare-and-swap (socket-writer-target-stream target)
                                                     client-stream nil)
                            (when client-stream
                              (ignore-errors (close client-stream :abort t)))
                            (ignore-errors (sb-bsd-sockets:socket-close client))))))))
      (setf (socket-writer-target-stream target) nil)
      (when kernel
        (handler-case (stop-kernel kernel :timeout 2)
          (serious-condition () nil)))
      (ignore-errors (sb-bsd-sockets:socket-close server))
      (unlink-socket-quietly socket-path))))

(defun main ()
  "Run the kernel for Emacs over standard input and output, or `--socket'."
  (sb-ext:disable-debugger)
  (let ((options (handler-case (parse-cli-options (rest sb-ext:*posix-argv*))
                   (message-error (condition)
                     (format *error-output* "lispm-kernel: ~A~%" (condition-text condition))
                     (finish-output *error-output*)
                     (sb-ext:exit :code 2)))))
    (when (eq options :version)
      (format t "lispm-kernel, protocol ~D, ~A ~A~%"
              +protocol+ (lisp-implementation-type) (lisp-implementation-version))
      (finish-output)
      (sb-ext:exit :code 0))
    (setf (sb-ext:bytes-consed-between-gcs) (* 16 1024 1024))
    (let* ((*cpu-workers* (or (getf options :cpu-workers) *cpu-workers*))
           (*io-workers* (or (getf options :io-workers) *io-workers*))
           (*subworkers* (or (getf options :subworkers) *subworkers*))
           (*max-requests* (or (getf options :max-requests) *max-requests*))
           (*max-requests-per-owner*
             (or (getf options :max-requests-per-owner) *max-requests-per-owner*))
           (*max-reactor-slots*
             (or (getf options :max-reactor-slots) *max-reactor-slots*))
           (*exec-stream-credit*
             (or (getf options :stream-credit) *exec-stream-credit*)))
      (if (getf options :socket)
          (run-socket-server (getf options :socket)
                             :cpu-workers *cpu-workers*
                             :io-workers *io-workers*
                             :subworkers *subworkers*
                             :reactor-slots *max-reactor-slots*
                             :on-ready (lambda (path)
                                         (ignore-errors
                                           (write-line (message-string (list 'listening :socket path)))
                                           (finish-output))))
          (let* ((input (sb-sys:make-fd-stream 0 :input t :buffering :full :name "Emacs"
                                                 :external-format '(:utf-8 :replacement #\REPLACEMENT_CHARACTER)))
                 (output (sb-sys:make-fd-stream 1 :output t :buffering :full :name "Emacs"
                                                  :external-format :utf-8))
                 (kernel (start-kernel (stream-sink output)
                                       :cpu-workers *cpu-workers*
                                       :io-workers *io-workers*
                                       :subworkers *subworkers*
                                       :reactor-slots *max-reactor-slots*)))
            (setf *kernel* kernel)
            (credit-sink-put-control (kernel-outbox kernel) (message-string (hello)))
            (unwind-protect
                 (handler-case
                     (loop for line = (read-line input nil nil)
                           while line
                           until (eq (handle-line kernel line) :quit))
                   (error (condition)
                     (format *error-output* "lispm-kernel: ~A~%" (condition-text condition))))
              (handler-case (stop-kernel kernel :timeout 2)
                (serious-condition () nil)))))
      (sb-ext:exit :code 0 :abort t))))
