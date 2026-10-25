;;;; files.lisp --- Stat with nanoseconds, directories, byte ranges

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

;;; Files are named by native namestrings, never CL pathnames, whose
;;; parsing would take * and [ in a name for wildcards.
;;;
;;; A file's stamp is what tells one version of it from another: its kind,
;;; size, modification and change times in nanoseconds, inode and device.
;;; Emacs's `file-attributes' has nanoseconds; sb-posix has seconds only,
;;; so the C library's stat is called here with struct stat laid out as
;;; each system lays it out.  The layout is checked against sb-posix once,
;;; on first use; where it is unknown or wrong, sb-posix's seconds serve.

(in-package #:lispm-kernel/files)

(defstruct (stamp (:constructor make-stamp (kind size mtime ctime inode device))
                  (:copier nil))
  "What one version of a file is."
  (kind :other :type (member :regular :directory :symlink :other) :read-only t)
  (size 0 :type integer :read-only t)
  (mtime 0 :type integer :read-only t)  ; nanoseconds since the epoch
  (ctime 0 :type integer :read-only t)
  (inode 0 :type integer :read-only t)
  (device 0 :type integer :read-only t))

(defun stamp= (a b)
  "Return true when stamps A and B are of one version of a file."
  (and a b
       (eq (stamp-kind a) (stamp-kind b))
       (= (stamp-size a) (stamp-size b))
       (= (stamp-mtime a) (stamp-mtime b))
       (= (stamp-ctime a) (stamp-ctime b))
       (= (stamp-inode a) (stamp-inode b))
       (= (stamp-device a) (stamp-device b))))

(defun mode-kind (mode)
  (case (logand mode #o170000)
    (#o100000 :regular)
    (#o040000 :directory)
    (#o120000 :symlink)
    (t :other)))

;;;; struct stat, as each system lays it out

;;; Offsets in bytes; DEVICE and MODE give their widths, the rest are 64
;;; bits; a time is a timespec, seconds then nanoseconds.
(defparameter *stat-layout*
  #+(and darwin (or arm64 x86-64))
  '(:bytes 144 :device (0 4) :mode (4 2) :inode 8 :mtime 48 :ctime 64 :size 96)
  #+(and linux x86-64)
  '(:bytes 144 :device (0 8) :inode 8 :mode (24 4) :size 48 :mtime 88 :ctime 104)
  #+(and linux arm64)
  '(:bytes 128 :device (0 8) :inode 8 :mode (16 4) :size 48 :mtime 88 :ctime 104)
  #-(or (and darwin (or arm64 x86-64)) (and linux (or x86-64 arm64)))
  nil
  "Where struct stat keeps what a stamp needs here, or nil when unknown.")

;;; Intel macOS names the stat of 64-bit inodes, the layout above, apart.
(defmacro define-stat-call (name c-name argument-type)
  `(defun ,name (argument buffer)
     (sb-alien:alien-funcall
      (sb-alien:extern-alien ,c-name (function sb-alien:int ,argument-type
                                               sb-alien:system-area-pointer))
      argument buffer)))

(define-stat-call %stat #+(and darwin x86-64) "stat$INODE64" #-(and darwin x86-64) "stat"
  sb-alien:c-string)
(define-stat-call %lstat #+(and darwin x86-64) "lstat$INODE64" #-(and darwin x86-64) "lstat"
  sb-alien:c-string)
(define-stat-call %fstat #+(and darwin x86-64) "fstat$INODE64" #-(and darwin x86-64) "fstat"
  sb-alien:int)

(defun layout-stamp (buffer)
  "Return the stamp in BUFFER, a struct stat laid out as `*stat-layout*'."
  (let ((sap (sb-sys:vector-sap buffer)))
    (flet ((field (name)
             (let ((place (getf *stat-layout* name)))
               (if (consp place)
                   (destructuring-bind (offset bytes) place
                     (ecase bytes
                       (2 (sb-sys:sap-ref-16 sap offset))
                       (4 (sb-sys:sap-ref-32 sap offset))
                       (8 (sb-sys:sap-ref-64 sap offset))))
                   (sb-sys:sap-ref-64 sap place))))
           (timespec (name)
             (let ((offset (getf *stat-layout* name)))
               (+ (* (sb-sys:signed-sap-ref-64 sap offset) 1000000000)
                  (sb-sys:signed-sap-ref-64 sap (+ offset 8))))))
      (make-stamp (mode-kind (field :mode))
                  (sb-sys:signed-sap-ref-64 sap (getf *stat-layout* :size))
                  (timespec :mtime) (timespec :ctime) (field :inode) (field :device)))))

(defun call-stamp (function argument)
  (let ((buffer (make-array (getf *stat-layout* :bytes) :element-type '(unsigned-byte 8))))
    (sb-sys:with-pinned-objects (buffer)
      (when (zerop (funcall function argument (sb-sys:vector-sap buffer)))
        (layout-stamp buffer)))))

(defun posix-stamp (stat)
  (make-stamp (mode-kind (sb-posix:stat-mode stat))
              (sb-posix:stat-size stat)
              (* (sb-posix:stat-mtime stat) 1000000000)
              (* (sb-posix:stat-ctime stat) 1000000000)
              (sb-posix:stat-ino stat)
              (sb-posix:stat-dev stat)))

(defvar *native-stat* :unknown
  "Whether the C library's stat is called with `*stat-layout*': :unknown
until first used, then t or nil.")

(defun check-native-stat ()
  "Return true when the native stat reads what sb-posix reads of /."
  (and *stat-layout*
       (ignore-errors
        (let ((native (call-stamp #'%stat "/"))
              (posix (posix-stamp (sb-posix:stat "/"))))
          (and native
               (eq (stamp-kind native) :directory)
               (= (stamp-inode native) (stamp-inode posix))
               (= (stamp-device native) (stamp-device posix))
               (= (stamp-size native) (stamp-size posix))
               (= (floor (stamp-mtime native) 1000000000)
                  (floor (stamp-mtime posix) 1000000000))
               (= (floor (stamp-ctime native) 1000000000)
                  (floor (stamp-ctime posix) 1000000000)))))))

(defun native-stat-p ()
  "Return true when stamps have nanoseconds, the native stat being right here."
  (when (eq *native-stat* :unknown)
    (setf *native-stat* (and (check-native-stat) t)))
  *native-stat*)

(defun file-stamp (path &key (follow t))
  "Return the stamp of the file PATH names, or nil when it cannot be had.
FOLLOW nil stamps a symbolic link itself, not what it points to."
  (handler-case
      (if (native-stat-p)
          (call-stamp (if follow #'%stat #'%lstat) path)
          (posix-stamp (if follow (sb-posix:stat path) (sb-posix:lstat path))))
    (error () nil)))

(defun descriptor-stamp (fd)
  (if (native-stat-p)
      (call-stamp #'%fstat fd)
      (handler-case (posix-stamp (sb-posix:fstat fd))
        (error () nil))))

;;;; Directories

(defun directory-names (path)
  "Return the names of the entries of directory PATH, but . and ..
The second value counts entries whose names could not be decoded, which
are left out; the third is nil when PATH could not be listed at all."
  (let ((directory (handler-case (sb-posix:opendir path)
                     (error () nil))))
    (if (or (null directory) (sb-alien:null-alien directory))
        (values '() 0 nil)
        (unwind-protect
             (let ((names '()) (undecodable 0))
               (loop
                 (let ((entry (handler-case (sb-posix:readdir directory)
                                (error () nil))))
                   (when (or (null entry) (sb-alien:null-alien entry))
                     (return))
                   (let ((name (handler-case (sb-posix:dirent-name entry)
                                 (error () (incf undecodable) nil))))
                     (when (and name (string/= name ".") (string/= name ".."))
                       (push name names)))))
               (values names undecodable t))
          (sb-posix:closedir directory)))))

;;;; Reading

(defun octet-lines (octets &key (start 0) (end (length octets)) drop-first drop-last)
  "Return the lines of OCTETS between START and END, decoded as UTF-8.
Invalid UTF-8 reads as U+FFFD.  DROP-FIRST leaves out the text up to the
first newline, cut by START; DROP-LAST the text after the last, cut by
END.  Empty lines are left out."
  (declare (type (simple-array (unsigned-byte 8) (*)) octets))
  (let ((lines '())
        (position start))
    (when drop-first
      (let ((newline (position 10 octets :start start :end end)))
        (setf position (if newline (1+ newline) end))))
    (loop
      (let ((newline (position 10 octets :start position :end end)))
        (when (and (null newline) drop-last)
          (return))
        (let ((stop (or newline end)))
          (when (< position stop)
            (push (sb-ext:octets-to-string octets :start position :end stop
                                                  :external-format '(:utf-8 :replacement #\REPLACEMENT_CHARACTER))
                  lines))
          (if newline
              (setf position (1+ newline))
              (return)))))
    (nreverse lines)))

(defun open-regular (path)
  "Return a descriptor of PATH open for reading and its stamp, or nil when
it is no regular file or cannot be opened.  It is opened without waiting,
so a FIFO in its place cannot hold the thread."
  (let ((fd (handler-case (sb-posix:open path (logior sb-posix:o-rdonly sb-posix:o-nonblock))
              (error () nil))))
    (when fd
      (let ((stamp (descriptor-stamp fd)))
        (if (and stamp (eq (stamp-kind stamp) :regular))
            (values fd stamp)
            (progn (sb-posix:close fd) nil))))))

(defun read-range (stream start end)
  "Return the octets of STREAM from START to END, fewer if it is shorter."
  (let ((buffer (make-array (- end start) :element-type '(unsigned-byte 8))))
    (file-position stream start)
    (let ((count (read-sequence buffer stream)))
      (if (= count (length buffer))
          buffer
          (subseq buffer 0 count)))))

(defmacro with-regular-file ((stream stamp path) &body body)
  "Run BODY with STREAM reading octets of regular file PATH, STAMP its
stamp; return nil without running it when PATH is none."
  (let ((fd (gensym "FD")))
    `(multiple-value-bind (,fd ,stamp) (open-regular ,path)
       (when ,fd
         (let ((,stream nil))
           (unwind-protect
                (progn
                  (setf ,stream (sb-sys:make-fd-stream ,fd :input t :element-type '(unsigned-byte 8)
                                                           :buffering :full :name ,path))
                  ,@body)
             (if ,stream (close ,stream) (sb-posix:close ,fd))))))))

(defun read-head-and-tail (path head-bytes tail-bytes)
  "Return the lines of the head and the tail of regular file PATH, and its
stamp, or nil when it is none or cannot be read.
The head is the first HEAD-BYTES, its last line left out when the file
goes on; the tail, read only when the file is longer than HEAD-BYTES, is
the last TAIL-BYTES after the head, its first line left out.  So lispm-agent
reads a transcript."
  (handler-case
      (with-regular-file (stream stamp path)
        (let* ((size (stamp-size stamp))
               (head-end (min size head-bytes))
               (head (read-range stream 0 head-end))
               (tail (when (and (> size head-bytes) (plusp tail-bytes))
                       (read-range stream (max head-bytes (- size tail-bytes)) size))))
          (values (octet-lines head :drop-last (< head-end size))
                  (and tail (octet-lines tail :drop-first t))
                  stamp)))
    (error () nil)))

(defun read-file-octets (path limit)
  "Return the octets of regular file PATH and its stamp, or nil when it is
none or cannot be read.  A file longer than LIMIT gives its last LIMIT
octets, and true as third value."
  (handler-case
      (with-regular-file (stream stamp path)
        (let ((size (stamp-size stamp)))
          (values (read-range stream (max 0 (- size limit)) size)
                  stamp
                  (> size limit))))
    (error () nil)))
