;;;; harness.lisp --- A small test harness for the kernel

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

;;; (deftest name () ...) defines a test; (is FORM) checks FORM, showing
;;; both sides of a failing (equal EXPECTED ACTUAL); (signals TYPE ...)
;;; checks that the body signals TYPE.  (run-tests) runs them all, in the
;;; order they were defined, and returns true when every one passed.

(defpackage #:lispm-kernel/test
  (:use #:common-lisp #:lispm-kernel/wire #:lispm-kernel/json #:lispm-kernel/files)
  (:export #:run-tests))

(in-package #:lispm-kernel/test)

(defvar *tests* '()
  "The tests, the last defined first.")

(defvar *test* nil "The test running.")
(defvar *checks* 0)
(defvar *failures* 0)

(defmacro deftest (name () &body body)
  `(progn
     (defun ,name () ,@body)
     (unless (member ',name *tests*)
       (push ',name *tests*))
     ',name))

(defun check (passed form values)
  (incf *checks*)
  (unless passed
    (incf *failures*)
    (format t "~&  FAIL in ~(~A~): ~S~@[~%    got ~S~]~%" *test* form values))
  passed)

(defmacro is (form)
  "Check that FORM is true.  For a comparison of two values, a failure
shows them."
  (if (and (consp form) (= (length form) 3)
           (member (first form) '(eq eql equal equalp = string= stamp=)))
      (let ((expected (gensym "EXPECTED")) (actual (gensym "ACTUAL")))
        `(let ((,expected ,(second form)) (,actual ,(third form)))
           (check (,(first form) ,expected ,actual) ',form (list ,expected ,actual))))
      `(check ,form ',form nil)))

(defmacro signals (type &body body)
  "Check that BODY signals a condition of TYPE."
  `(check (handler-case (progn ,@body nil)
            (,type () t))
          '(signals ,type ,@body)
          nil))

(defun run-tests (&optional (tests (reverse *tests*)))
  "Run TESTS, by default all; return true when all passed."
  (let ((*checks* 0) (*failures* 0) (errors 0))
    (dolist (test tests)
      (let ((*test* test))
        (handler-case (funcall test)
          (serious-condition (condition)
            (incf errors)
            (format t "~&  ERROR in ~(~A~): ~A~%" test condition)))))
    (format t "~&~D tests, ~D checks, ~D failed, ~D errors~%"
            (length tests) *checks* *failures* errors)
    (and (zerop *failures*) (zerop errors))))

;;;; Settings for tests

(defmacro with-globals ((&rest bindings) &body body)
  "Run BODY with the global values of the variables of BINDINGS, (VARIABLE
VALUE), set, as the kernel's threads see them, and restored after."
  (let ((saved (loop repeat (length bindings) collect (gensym "SAVED"))))
    `(let ,(loop for (variable) in bindings for old in saved collect `(,old ,variable))
       (unwind-protect
            (progn (setf ,@(loop for (variable value) in bindings append (list variable value)))
                   ,@body)
         (setf ,@(loop for (variable) in bindings for old in saved append (list variable old)))))))

;;;; Files for tests

(defun temporary-directory ()
  "Make a new directory for a test and return its name, without a slash."
  (let ((base (string-right-trim "/" (or (sb-posix:getenv "TMPDIR") "/tmp"))))
    (sb-posix:mkdtemp (concatenate 'string base "/lispm-kernel-test-XXXXXX"))))

(defun delete-tree (directory)
  (uiop:delete-directory-tree (uiop:ensure-directory-pathname (sb-ext:parse-native-namestring directory))
                              :validate t :if-does-not-exist :ignore))

(defmacro with-directory ((directory) &body body)
  "Run BODY with DIRECTORY bound to a new directory, deleted after."
  `(let ((,directory (temporary-directory)))
     (unwind-protect (progn ,@body)
       (delete-tree ,directory))))

(defun path (&rest parts)
  (format nil "~{~A~^/~}" parts))

(defun write-file (path &rest lines)
  "Write LINES to PATH, each ending with a newline, making its directory."
  (ensure-directories-exist (sb-ext:parse-native-namestring path))
  (with-open-file (stream (sb-ext:parse-native-namestring path) :direction :output
                                                                 :if-exists :supersede
                                                                 :external-format :utf-8)
    (dolist (line lines)
      (write-string line stream)
      (terpri stream)))
  path)

(defun write-octets (path octets)
  (ensure-directories-exist (sb-ext:parse-native-namestring path))
  (with-open-file (stream (sb-ext:parse-native-namestring path) :direction :output
                                                                 :if-exists :supersede
                                                                 :element-type '(unsigned-byte 8))
    (write-sequence octets stream))
  path)

(defun make-directory (path)
  (ensure-directories-exist (sb-ext:parse-native-namestring (concatenate 'string path "/")))
  path)

(defun set-mtime (path seconds)
  (sb-posix:utimes path seconds seconds)
  path)

(defun octets (string)
  (sb-ext:string-to-octets string :external-format :utf-8))

(defun chars (&rest codes)
  (map 'string #'code-char codes))
