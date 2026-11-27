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
;;; line, and writes its own to its standard output (or Unix domain
;;; socket when started with `--socket').  It says hello first:
;;;
;;;   (hello :protocol 1 :pid PID :epoch EPOCH :lisp "SBCL 2.6.9" ...)
;;;
;;; Over stdio it ends when its standard input does or on `(quit)'.
;;; Over `--socket' client EOF detaches Emacs while `P_agents' stays
;;; alive until `(quit)' is received.

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

(defun hello (&optional kernel)
  "Construct the initial `(hello ...)' greeting form for optional KERNEL."
  (list 'hello
        :protocol +protocol+
        :pid (sb-posix:getpid)
        :epoch (if kernel (kernel-epoch kernel) (next-kernel-epoch))
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
  "Return a sink writing messages to STREAM, one per line."
  (lambda (messages)
    (handler-case
        (progn
          (dolist (message messages)
            (when (plusp (length message))
              (write-string message stream)
              (write-char #\Newline stream)))
          (finish-output stream))
      (stream-error ()
        (handler-case
            (when *kernel*
              (stop-kernel *kernel* :timeout 2))
          (serious-condition () nil))
        (sb-ext:exit :code 0 :abort t)))))

;;;; Reconnectable Unix domain socket daemon transport (single-owner P_writer)

(defstruct (socket-writer (:constructor make-socket-writer ()) (:copier nil))
  "CSP command channel giving `P_writer' exclusive ownership of client write streams."
  (commands (sb-concurrency:make-queue :name "socket-writer-commands")
   :type sb-concurrency:queue :read-only t)
  ;; Owned and mutated strictly by `P_writer'.
  (stream nil))

(defun socket-writer-drain-commands (writer)
  "Process pending `:attach' and `:detach' stream handoffs inside `P_writer'."
  (let ((cmds (socket-writer-commands writer)))
    (loop
      (multiple-value-bind (cmd ok) (sb-concurrency:dequeue cmds)
        (unless ok (return))
        (ecase (first cmd)
          (:attach
           (let ((old (socket-writer-stream writer)))
             (when old
               (ignore-errors (close old :abort t))))
           (setf (socket-writer-stream writer) (second cmd)))
          (:detach
           (let ((old (socket-writer-stream writer)))
             (setf (socket-writer-stream writer) nil)
             (when old
               (ignore-errors (close old :abort t)))
             (sb-concurrency:open-gate (second cmd)))))))))

(defun socket-sink (writer)
  "Return a `P_writer' sink owning client write streams via WRITER commands."
  (lambda (messages)
    (socket-writer-drain-commands writer)
    (let ((stream (socket-writer-stream writer)))
      (when stream
        (handler-case
            (let ((wrote nil))
              (dolist (message messages)
                (when (plusp (length message))
                  (write-string message stream)
                  (write-char #\Newline stream)
                  (setf wrote t)))
              (when wrote
                (finish-output stream)))
          ((or stream-error sb-bsd-sockets:socket-error) ()
            (setf (socket-writer-stream writer) nil)
            (ignore-errors (close stream :abort t))))))))

(defun unlink-socket-quietly (path)
  "Remove Unix domain socket PATH if present, ignoring syscall errors."
  (handler-case (sb-posix:unlink path)
    (sb-posix:syscall-error () nil)))

(defun socket-in-use-p (path)
  "Return true when an active listener responds on Unix domain socket PATH."
  (let ((probe (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (unwind-protect
         (handler-case
             (progn
               (sb-bsd-sockets:socket-connect probe path)
               t)
           ((or sb-bsd-sockets:socket-error file-error sb-posix:syscall-error) () nil))
      (ignore-errors (sb-bsd-sockets:socket-close probe)))))

(defun bind-private-local-socket (server socket-path)
  "Bind SERVER at SOCKET-PATH atomically with `0700' umask and `0600' mode."
  (let ((old-mask (sb-posix:umask #o077)))
    (unwind-protect
         (sb-bsd-sockets:socket-bind server socket-path)
      (sb-posix:umask old-mask)))
  (sb-posix:chmod socket-path #o600)
  (sb-bsd-sockets:socket-listen server 16))

(defun serve-socket-client (kernel writer client)
  "Serve one accepted Unix socket CLIENT using split read/write fds; return QUIT-P."
  (let ((in-stream nil)
        (out-stream nil)
        (out-fd nil)
        (handed-off nil)
        (quit-requested nil))
    (unwind-protect
         (handler-case
             (progn
               (setf out-fd (sb-posix:dup (sb-bsd-sockets:socket-file-descriptor client))
                     in-stream (sb-bsd-sockets:socket-make-stream
                                client
                                :input t :output nil
                                :buffering :full
                                :element-type 'character
                                :external-format '(:utf-8 :replacement #\REPLACEMENT_CHARACTER))
                     out-stream (sb-sys:make-fd-stream
                                 out-fd
                                 :output t
                                 :buffering :full
                                 :element-type 'character
                                 :external-format :utf-8
                                 :name "lispm-socket-out"))
               (write-line (message-string (hello kernel)) out-stream)
               (finish-output out-stream)
               (sb-concurrency:enqueue (list :attach out-stream) (socket-writer-commands writer))
               (setf handed-off t)
               (loop for line = (read-line in-stream nil nil)
                     while line
                     when (eq (handle-line kernel line) :quit)
                       do (setf quit-requested t)
                          (return)))
           ((or stream-error sb-bsd-sockets:socket-error sb-posix:syscall-error) () nil))
      (when handed-off
        (let ((gate (sb-concurrency:make-gate :name "sock-detach" :open nil)))
          (sb-concurrency:enqueue (list :detach gate) (socket-writer-commands writer))
          (credit-sink-put-control (kernel-outbox kernel) "")
          (sb-concurrency:wait-on-gate gate :timeout 2)))
      (when (and out-stream (not handed-off))
        (ignore-errors (close out-stream :abort t)))
      (when (and out-fd (not out-stream) (not handed-off))
        (ignore-errors (sb-posix:close out-fd)))
      (when in-stream
        (ignore-errors (close in-stream :abort t)))
      (ignore-errors (sb-bsd-sockets:socket-close client)))
    quit-requested))

(defun run-socket-server (socket-path &key cpu-workers io-workers subworkers reactor-slots on-ready)
  "Serve the CSP kernel over Unix domain socket SOCKET-PATH across reconnects.
Client EOF detaches Emacs while keeping all running `P_agents' alive; `(quit)'
shuts down both kernel and socket listener.  ON-READY, when non-nil, is called
with SOCKET-PATH once bound and listening."
  (when (socket-in-use-p socket-path)
    (message-error "Socket ~A is already in use by an active kernel" socket-path))
  (unlink-socket-quietly socket-path)
  (let* ((server (make-instance 'sb-bsd-sockets:local-socket :type :stream))
         (writer (make-socket-writer))
         (kernel nil)
         (bound nil))
    (unwind-protect
         (progn
           (bind-private-local-socket server socket-path)
           (setf bound t
                 kernel (start-kernel (socket-sink writer)
                                      :cpu-workers (or cpu-workers *cpu-workers*)
                                      :io-workers (or io-workers *io-workers*)
                                      :subworkers (or subworkers *subworkers*)
                                      :reactor-slots (or reactor-slots *max-reactor-slots*)))
           (when on-ready
             (funcall on-ready socket-path))
           (loop
             for client = (handler-case (sb-bsd-sockets:socket-accept server)
                            ((or sb-bsd-sockets:socket-error sb-posix:syscall-error) () nil))
             while client
             until (serve-socket-client kernel writer client)))
      (when kernel
        (handler-case (stop-kernel kernel :timeout 2)
          (serious-condition () nil)))
      (ignore-errors (sb-bsd-sockets:socket-close server))
      (when bound
        (unlink-socket-quietly socket-path)))))

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
            (credit-sink-put-control (kernel-outbox kernel) (message-string (hello kernel)))
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
