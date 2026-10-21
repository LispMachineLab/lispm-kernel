;;;; files-test.lisp --- Tests of stamps, directories and byte ranges

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

(in-package #:lispm-kernel/test)

(deftest files-native-stat-where-its-layout-is-known ()
  (when lispm-kernel/files::*stat-layout*
    (is (native-stat-p))))

(deftest files-stamps ()
  (with-directory (directory)
    (let* ((file (write-file (path directory "a.jsonl") "line"))
           (stamp (file-stamp file))
           (posix (sb-posix:stat file)))
      (is (eq :regular (stamp-kind stamp)))
      (is (= 5 (stamp-size stamp)))
      (is (= (sb-posix:stat-ino posix) (stamp-inode stamp)))
      (is (= (sb-posix:stat-mtime posix) (floor (stamp-mtime stamp) 1000000000)))
      (is (stamp= stamp (file-stamp file)))
      (set-mtime file 1000000000)
      (is (= (* 1000000000 1000000000) (stamp-mtime (file-stamp file))))
      (is (not (stamp= stamp (file-stamp file))))
      (is (eq :directory (stamp-kind (file-stamp directory))))
      (sb-posix:symlink file (path directory "link"))
      (sb-posix:symlink (path directory "gone") (path directory "broken"))
      (is (eq :symlink (stamp-kind (file-stamp (path directory "link") :follow nil))))
      (is (eq :regular (stamp-kind (file-stamp (path directory "link")))))
      (is (eq :symlink (stamp-kind (file-stamp (path directory "broken") :follow nil))))
      (is (eq nil (file-stamp (path directory "broken"))))
      (is (eq nil (file-stamp (path directory "missing")))))))

(deftest files-nanoseconds ()
  (when (native-stat-p)
    (with-directory (directory)
      ;; Some second's fraction shows, written twice a little apart.
      (let ((times (loop repeat 3
                         collect (stamp-mtime (file-stamp (write-file (path directory "f") "x")))
                         do (sleep 0.013))))
        (is (some (lambda (time) (plusp (mod time 1000000000))) times))))))

(deftest files-directory-names ()
  (with-directory (directory)
    (write-file (path directory "b") "")
    (make-directory (path directory ".hidden"))
    (write-file (path directory "a [*].jsonl") "")
    (multiple-value-bind (names undecodable listed) (directory-names directory)
      (is (equal '(".hidden" "a [*].jsonl" "b") (sort names #'string<)))
      (is (= 0 undecodable))
      (is listed))
    (is (eq nil (nth-value 2 (directory-names (path directory "missing")))))))

(deftest files-octet-lines ()
  (let ((octets (octets (format nil "cut~%one~%~%two~%tail"))))
    (is (equal '("cut" "one" "two" "tail") (octet-lines octets)))
    (is (equal '("one" "two" "tail") (octet-lines octets :drop-first t)))
    (is (equal '("cut" "one" "two") (octet-lines octets :drop-last t)))
    (is (equal '("one" "two") (octet-lines octets :drop-first t :drop-last t)))
    (is (equal '() (octet-lines (octets "no newline") :drop-first t)))
    (is (equal '("x") (octet-lines (octets (format nil "x~%")) :drop-last t))))
  (is (equal (list (chars #x61 #xFFFD #x62))
             (octet-lines (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(97 255 98))))))

(defun numbered-lines (count width)
  "Return COUNT lines of WIDTH characters, each starting with its number."
  (loop for index from 0 below count
        collect (let ((line (make-string width :initial-element #\x)))
                  (replace line (format nil "~6,'0D" index))
                  line)))

(deftest files-head-and-tail ()
  (with-directory (directory)
    ;; 1000 lines of 99 characters and a newline: 100000 bytes.
    (let ((file (apply #'write-file (path directory "big") (numbered-lines 1000 99))))
      (multiple-value-bind (head tail stamp) (read-head-and-tail file 65536 16384)
        (is (= 100000 (stamp-size stamp)))
        ;; Line 655 is cut by the head's end, and line 836 by the tail's start.
        (is (= 655 (length head)))
        (is (string= "000654" (subseq (car (last head)) 0 6)))
        (is (string= "000837" (subseq (first tail) 0 6)))
        (is (string= "000999" (subseq (car (last tail)) 0 6)))))
    (let ((file (write-octets (path directory "small") (octets (format nil "a~%b~%c")))))
      (multiple-value-bind (head tail) (read-head-and-tail file 65536 16384)
        (is (equal '("a" "b" "c") head))
        (is (eq nil tail))))
    ;; Longer than the head, with its tail starting inside the head: only after.
    (let ((file (apply #'write-file (path directory "medium") (numbered-lines 700 99))))
      (multiple-value-bind (head tail) (read-head-and-tail file 65536 16384)
        (is (= 655 (length head)))
        (is (string= "000656" (subseq (first tail) 0 6)))))))

(deftest files-only-regular-files-are-read ()
  (with-directory (directory)
    (let ((fifo (path directory "fifo")))
      (sb-posix:mkfifo fifo #o600)
      ;; Opened without waiting for a writer, then refused.
      (is (eq nil (read-head-and-tail fifo 65536 16384)))
      (is (eq nil (read-file-octets fifo 100))))
    (is (eq nil (read-head-and-tail directory 65536 16384)))
    (is (eq nil (read-head-and-tail (path directory "missing") 65536 16384)))))

(deftest files-whole-files ()
  (with-directory (directory)
    (let ((file (write-octets (path directory "f") (octets "0123456789"))))
      (multiple-value-bind (octets stamp cut) (read-file-octets file 100)
        (is (equalp (octets "0123456789") octets))
        (is (= 10 (stamp-size stamp)))
        (is (not cut)))
      (multiple-value-bind (octets stamp cut) (read-file-octets file 4)
        (declare (ignore stamp))
        (is (equalp (octets "6789") octets))
        (is cut)))))
