;;;; exec.lisp --- Event-multiplexed subprocess execution without polling

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

;;; Single-worker non-blocking `poll(2)' multiplexer for external programs:
;;;
;;;   [wakeup-rfd, stdin-fd, stdout-fd, stderr-fd] ──▶ unix-poll ──▶ emit chunks
;;;
;;; A lock-free refcounted wakeup pipe bridges both `SIGCHLD' (`:status-hook')
;;; and CSP `cancel-token' hooks directly into `poll(2)', eliminating helper
;;; stdin feeder threads and periodic sleep polling.  Standard error is kept
;;; in a fixed-size circular byte ring buffer.

(in-package #:lispm-kernel)

(defparameter *exec-read-octets* 65536
  "Octets of a program's output read at a time, at most.")

(defparameter *exec-stderr-limit* 65536
  "Octets of a program's standard error kept, the last.")

(defparameter *exec-kill-seconds* 1
  "Seconds a program stopped with SIGTERM has to exit before SIGKILL.")

;;;; UTF-8 framing and fixed-capacity stderr ring buffer

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

(defstruct (byte-ring (:constructor make-byte-ring (capacity)) (:copier nil))
  "Circular byte buffer retaining at most the last CAPACITY octets."
  (capacity 0 :type fixnum :read-only t)
  (data (make-array capacity :element-type '(unsigned-byte 8))
   :type (simple-array (unsigned-byte 8) (*)) :read-only t)
  (head 0 :type fixnum)
  (filled 0 :type fixnum))

(defun byte-ring-write (ring source count)
  "Append the first COUNT octets of SOURCE into RING in O(min(COUNT, CAPACITY))."
  (let ((cap (byte-ring-capacity ring)))
    (when (and (plusp cap) (plusp count))
      (let* ((skip (max 0 (- count cap)))
             (take (- count skip))
             (head (byte-ring-head ring))
             (first-part (min take (- cap head)))
             (second-part (- take first-part))
             (data (byte-ring-data ring)))
        (replace data source :start1 head :end1 (+ head first-part)
                             :start2 skip :end2 (+ skip first-part))
        (when (plusp second-part)
          (replace data source :start1 0 :end1 second-part
                               :start2 (+ skip first-part) :end2 count))
        (setf (byte-ring-head ring) (mod (+ head take) cap)
              (byte-ring-filled ring) (min cap (+ (byte-ring-filled ring) take)))))))

(defun byte-ring-string (ring)
  "Decode the retained tail of RING as UTF-8."
  (let ((filled (byte-ring-filled ring))
        (cap (byte-ring-capacity ring))
        (head (byte-ring-head ring))
        (data (byte-ring-data ring)))
    (cond ((zerop filled) "")
          ((< filled cap) (utf-8-text data 0 filled))
          (t (let ((out (make-array cap :element-type '(unsigned-byte 8))))
               (replace out data :start1 0 :start2 head :end2 cap)
               (replace out data :start1 (- cap head) :start2 0 :end2 head)
               (utf-8-text out 0 cap))))))

;;;; Non-blocking descriptors, lock-free wakeup pipe and POSIX poll(2)

(defun set-fd-nonblocking (fd)
  "Enable O_NONBLOCK on file descriptor FD."
  (let ((flags (sb-posix:fcntl fd sb-posix:f-getfl)))
    (sb-posix:fcntl fd sb-posix:f-setfl (logior flags sb-posix:o-nonblock))))

;;; Lower 32 bits of `state' hold `(1+ wfd)' (0 once closed); upper 32 bits
;;; count in-flight `wakeup-poke' writers so `wfd' is never closed or reused
;;; mid-write, without taking any lock inside signal or cancel hooks.
(defstruct (wakeup-pipe (:constructor %make-wakeup-pipe (rfd state)) (:copier nil))
  (rfd -1 :type fixnum :read-only t)
  (state 0 :type sb-ext:word)
  (byte (make-array 1 :element-type '(unsigned-byte 8) :initial-element 1)
   :type (simple-array (unsigned-byte 8) (1)) :read-only t))

(defun open-wakeup-pipe ()
  "Create a non-blocking wakeup pipe, closing descriptors on setup failure."
  (multiple-value-bind (rfd wfd) (sb-posix:pipe)
    (let ((ok nil))
      (unwind-protect
           (progn
             (set-fd-nonblocking rfd)
             (set-fd-nonblocking wfd)
             (prog1 (%make-wakeup-pipe rfd (1+ wfd))
               (setf ok t)))
        (unless ok
          (handler-case (sb-posix:close rfd)
            (sb-posix:syscall-error () nil))
          (handler-case (sb-posix:close wfd)
            (sb-posix:syscall-error () nil)))))))

(defun wakeup-poke (pipe)
  "Write one byte to PIPE if still open; async-signal-safe (`SIGCHLD') and lock-free."
  (let ((pin-step (ash 1 32)))
    (loop
      (let ((old (wakeup-pipe-state pipe)))
        (when (zerop (ldb (byte 32 0) old))
          (return nil))
        (when (eql old (sb-ext:compare-and-swap (wakeup-pipe-state pipe) old (+ old pin-step)))
          (let ((wfd (1- (ldb (byte 32 0) old))))
            (unwind-protect
                 (sb-unix:unix-write wfd (wakeup-pipe-byte pipe) 0 1)
              (loop
                (let* ((cur (wakeup-pipe-state pipe))
                       (next (- cur pin-step)))
                  (when (eql cur (sb-ext:compare-and-swap (wakeup-pipe-state pipe) cur next))
                    (when (and (zerop (ldb (byte 32 0) next))
                               (zerop (ash next -32)))
                      (sb-unix:unix-close wfd))
                    (return))))))
          (return t))))))

(defun drain-wakeup-pipe (pipe scratch)
  "Drain pending wakeup bytes from PIPE into SCRATCH."
  (loop
    (multiple-value-bind (count errno)
        (sb-sys:with-pinned-objects (scratch)
          (sb-unix:unix-read (wakeup-pipe-rfd pipe) (sb-sys:vector-sap scratch) (length scratch)))
      (declare (ignore errno))
      (when (or (null count) (zerop count))
        (return)))))

(defun close-wakeup-pipe (pipe)
  "Close both ends of PIPE safely."
  (let ((wfd-to-close nil))
    (loop
      (let ((old (wakeup-pipe-state pipe)))
        (when (zerop (ldb (byte 32 0) old))
          (return))
        (let ((cleared (logand old (ash #xFFFFFFFF 32))))
          (when (eql old (sb-ext:compare-and-swap (wakeup-pipe-state pipe) old cleared))
            (when (zerop (ash cleared -32))
              (setf wfd-to-close (1- (ldb (byte 32 0) old))))
            (return)))))
    (when wfd-to-close
      (handler-case (sb-posix:close wfd-to-close)
        (sb-posix:syscall-error () nil)))
    (handler-case (sb-posix:close (wakeup-pipe-rfd pipe))
      (sb-posix:syscall-error () nil))))

(defun unix-poll-fds (pollbuf count timeout-ms)
  "Call POSIX `poll(2)' on COUNT 8-byte `struct pollfd' entries in POLLBUF."
  (sb-sys:with-pinned-objects (pollbuf)
    (let ((rc (sb-alien:alien-funcall
               (sb-alien:extern-alien "poll"
                                      (function sb-alien:int
                                                sb-alien:system-area-pointer
                                                sb-alien:unsigned-int
                                                sb-alien:int))
               (sb-sys:vector-sap pollbuf) count timeout-ms)))
      (if (< rc 0) 0 rc))))

(defconstant +pollin+ #x0001
  "POSIX `POLLIN' event bit for `struct pollfd'.")

(defconstant +pollout+ #x0004
  "POSIX `POLLOUT' event bit for `struct pollfd'.")

(defun set-pollfd (pollbuf slot fd events)
  "Encode FD and EVENTS into 8-byte `struct pollfd' entry SLOT inside POLLBUF."
  (let ((sap (sb-sys:vector-sap pollbuf))
        (offset (* slot 8)))
    (setf (sb-sys:signed-sap-ref-32 sap offset) fd
          (sb-sys:signed-sap-ref-16 sap (+ offset 4)) events
          (sb-sys:signed-sap-ref-16 sap (+ offset 6)) 0)))

(defun pollfd-revents (pollbuf slot)
  "Read the 16-bit `revents' field of `struct pollfd' entry SLOT in POLLBUF."
  (sb-sys:signed-sap-ref-16 (sb-sys:vector-sap pollbuf) (+ (* slot 8) 6)))

(defun wait-wakeup-pipe (pipe timeout-ms)
  "Wait up to TIMEOUT-MS milliseconds on PIPE via `poll(2)' and drain it."
  (let ((pollbuf (make-array 8 :element-type '(unsigned-byte 8) :initial-element 0))
        (scratch (make-array 64 :element-type '(unsigned-byte 8))))
    (sb-sys:with-pinned-objects (pollbuf)
      (set-pollfd pollbuf 0 (wakeup-pipe-rfd pipe) +pollin+))
    (unix-poll-fds pollbuf 1 (max 0 timeout-ms))
    (drain-wakeup-pipe pipe scratch)))

(defun read-nonblocking (fd buffer start)
  "Read available octets from non-blocking FD into BUFFER from START.
Return byte count (> 0), 0 on EOF, or `:would-block'."
  (loop
    (multiple-value-bind (count errno)
        (sb-sys:with-pinned-objects (buffer)
          (sb-unix:unix-read fd (sb-sys:sap+ (sb-sys:vector-sap buffer) start)
                             (- (length buffer) start)))
      (cond (count (return count))
            ((= errno sb-unix:eintr))
            ((or (= errno sb-posix:eagain) (= errno sb-posix:ewouldblock))
             (return :would-block))
            (t (exec-error "Reading the program's output failed: ~A"
                           (sb-int:strerror errno)))))))

;;;; Process lifecycle and environment preparation

(defun stop-process (process pipe &optional (kill-seconds *exec-kill-seconds*))
  "Stop PROCESS and its process group: SIGTERM, polling PIPE up to
KILL-SECONDS for `SIGCHLD', then SIGKILL."
  (when (sb-ext:process-alive-p process)
    (sb-ext:process-kill process sb-posix:sigterm :process-group)
    (let ((deadline (+ (get-internal-real-time)
                       (* kill-seconds internal-time-units-per-second))))
      (loop while (sb-ext:process-alive-p process)
            for remaining-ms = (compute-poll-timeout-ms t deadline)
            while (plusp remaining-ms)
            do (wait-wakeup-pipe pipe remaining-ms)))
    (when (sb-ext:process-alive-p process)
      (sb-ext:process-kill process sb-posix:sigkill :process-group))
    (sb-ext:process-wait process)))

(defun environment-name (entry)
  "Return the variable name before #\\= in ENTRY."
  (let ((pos (position #\= entry)))
    (if pos (subseq entry 0 pos) entry)))

(defun exec-environment (env &optional inherit)
  "Return ENV as run-program takes an environment, or the kernel's own for nil.
When INHERIT is non-nil, merge ENV over the kernel's own environment."
  (cond ((null env)
         (sb-ext:posix-environ))
        (t
         (check-type env list)
         (dolist (entry env)
           (unless (and (stringp entry) (find #\= entry))
             (exec-error "An environment entry is NAME=VALUE, not ~S" entry)))
         (if (not inherit)
             env
             (let ((seen (make-hash-table :test #'equal))
                   (merged nil))
               (dolist (entry env)
                 (let ((name (environment-name entry)))
                   (unless (gethash name seen)
                     (setf (gethash name seen) t)
                     (push entry merged))))
               (dolist (entry (sb-ext:posix-environ))
                 (let ((name (environment-name entry)))
                   (unless (gethash name seen)
                     (setf (gethash name seen) t)
                     (push entry merged))))
               (nreverse merged))))))

;;;; Non-blocking stdin pump and poll timeout helper

(defun pump-stdin-fd (fd octets offset stream)
  "Write available slices of OCTETS from OFFSET to non-blocking FD.
Return (values OPEN-P NEXT-OFFSET), closing STREAM on completion or EPIPE."
  (let ((total (length octets)))
    (loop while (< offset total)
          do (multiple-value-bind (written errno)
                 (sb-unix:unix-write fd octets offset (min 65536 (- total offset)))
               (cond (written
                      (incf offset written))
                     ((= errno sb-unix:eintr))
                     ((or (= errno sb-posix:eagain) (= errno sb-posix:ewouldblock))
                      (return-from pump-stdin-fd (values t offset)))
                     (t
                      (close stream :abort t)
                      (return-from pump-stdin-fd (values nil total))))))
    (close stream :abort t)
    (values nil total)))

(defun compute-poll-timeout-ms (alive deadline)
  "Compute the `poll(2)' timeout in milliseconds."
  (cond ((not alive) 0)
        (deadline
         (let ((remaining (- deadline (get-internal-real-time))))
           (if (<= remaining 0)
               0
               (min 1000 (ceiling (* remaining 1000) internal-time-units-per-second)))))
        (t 1000)))

;;;; Validated reactor job specs (`exec' and `http-stream')

(defstruct (exec-spec (:constructor make-exec-spec
                       (&key program args cwd env env-inherit stdin timeout
                             search combine-error cleanup-path))
                      (:copier nil))
  "Validated process launch specification executed by `P_reactor'."
  (program "" :type string :read-only t)
  (args '() :type list :read-only t)
  (cwd nil :type (or null string) :read-only t)
  (env nil :type list :read-only t)
  (env-inherit nil :type boolean :read-only t)
  (stdin nil :type (or null string) :read-only t)
  (timeout nil :type (or null (integer 1 86400)) :read-only t)
  (search nil :type boolean :read-only t)
  (combine-error nil :type boolean :read-only t)
  (cleanup-path nil :type (or null string) :read-only t))

(define-job (exec :class :reactor) (input)
  "Validate INPUT for running PROGRAM and return an `exec-spec' for `P_reactor'."
  (destructuring-bind (&key program args cwd env env-inherit stdin timeout combine-error search) input
    (check-type program string)
    (check-type args list)
    (dolist (arg args) (check-type arg string))
    (check-type cwd (or null string))
    (check-type stdin (or null string))
    (check-type timeout (or null (integer 1 86400)))
    (unless (and (plusp (length program))
                 (or search (char= (char program 0) #\/)))
      (exec-error "The program to run is a file, not ~S" program))
    (make-exec-spec :program program
                    :args args
                    :cwd cwd
                    :env (exec-environment env env-inherit)
                    :env-inherit (and env-inherit t)
                    :stdin stdin
                    :timeout timeout
                    :search (and search t)
                    :combine-error (and combine-error t))))

(defparameter *http-status-marker* (format nil "~%__LISPM_HTTP_STATUS__:")
  "Separator curl prints before the HTTP status code.")

(defun curl-header-config (headers)
  "Return curl's --config input sending HEADERS, a list of \"Name: value\" strings."
  (with-output-to-string (out)
    (dolist (header headers)
      (check-type header string)
      (write-string "header = \"" out)
      (loop for char across header
            do (when (or (char= char #\\) (char= char #\"))
                 (write-char #\\ out))
               (write-char char out))
      (write-string "\"" out)
      (terpri out))))

(defun temporary-request-file (body)
  "Write BODY, a UTF-8 string, to a new temporary file and return its native path."
  (let* ((base (string-right-trim "/" (or (sb-posix:getenv "TMPDIR") "/tmp")))
         (template (concatenate 'string base "/lispm-http-XXXXXX")))
    (multiple-value-bind (fd path) (sb-posix:mkstemp template)
      (let ((ok nil))
        (unwind-protect
             (let ((stream (sb-sys:make-fd-stream fd :output t :element-type '(unsigned-byte 8)
                                                     :buffering :full)))
               (unwind-protect
                    (progn
                      (write-sequence (sb-ext:string-to-octets body :external-format :utf-8) stream)
                      (finish-output stream)
                      (setf ok t)
                      path)
                 (close stream)))
          (unless ok
            (handler-case (sb-posix:close fd) (sb-posix:syscall-error () nil))
            (handler-case (sb-posix:unlink path) (sb-posix:syscall-error () nil))))))))

(define-job (http-stream :class :reactor) (input)
  "Validate INPUT and return an `exec-spec' streaming URL via curl in `P_reactor'."
  (destructuring-bind (&key url headers (body "") (curl "curl")
                            (connect-timeout 30) (speed-time 600) (max-time 900) env)
      input
    (check-type url string)
    (check-type headers list)
    (check-type body string)
    (check-type curl string)
    (check-type connect-timeout (integer 1 3600))
    (check-type speed-time (integer 1 86400))
    (check-type max-time (integer 1 86400))
    (let* ((header-config (curl-header-config headers))
           (resolved-env (exec-environment env nil))
           (file (temporary-request-file body)))
      (make-exec-spec
       :program curl
       :args (list "--silent" "--show-error" "--no-buffer"
                   "-H" "Expect:"
                   "--connect-timeout" (princ-to-string connect-timeout)
                   "--speed-limit" "1"
                   "--speed-time" (princ-to-string speed-time)
                   "--max-time" (princ-to-string max-time)
                   "--config" "-"
                   "--data-binary" (concatenate 'string "@" file)
                   "--write-out" (concatenate 'string *http-status-marker* "%{http_code}"
                                              (string #\Newline))
                   url)
       :env resolved-env
       :stdin header-config
       :timeout (+ max-time 15)
       :search (not (and (plusp (length curl)) (char= (char curl 0) #\/)))
       :cleanup-path file))))
