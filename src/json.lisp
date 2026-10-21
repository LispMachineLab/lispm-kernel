;;;; json.lisp --- JSON, as agents write their transcripts

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

;;; Strict JSON (RFC 8259), read the way LispM Desktop reads it in Emacs,
;;; `json-parse-string' with :null-object and :false-object nil and lists
;;; for arrays:
;;;
;;;   JSON    {"a": 1}   [1, 2]   "x"   true   false   null   1.5
;;;   Lisp    object     (1 2)    "x"   T      NIL     NIL    number
;;;
;;; An object keeps its members in order and `json-get' finds the first of
;;; a name.  Numbers keep their text: what is read here never computes
;;; with them, only asks whether they are there.

(in-package #:lispm-kernel/json)

(define-condition json-error (error)
  ((position :initarg :position :reader json-error-position)
   (what :initarg :what :reader json-error-what))
  (:report (lambda (condition stream)
             (format stream "Invalid JSON at ~D: ~A"
                     (json-error-position condition) (json-error-what condition))))
  (:documentation "Text that is not one JSON value."))

(defstruct (json-object (:constructor make-json-object (pairs)) (:copier nil))
  "A JSON object: its members as (NAME . VALUE), in order."
  (pairs '() :type list :read-only t))

(defstruct (json-number (:constructor make-json-number (text)) (:copier nil))
  "A JSON number, as written."
  (text "" :type string :read-only t))

(defun json-get (object name)
  "Return the value of the first member NAME of OBJECT, or nil.
OBJECT may be any value: what is no object has no members."
  (when (json-object-p object)
    (cdr (assoc name (json-object-pairs object) :test #'string=))))

(defconstant +max-depth+ 512
  "How deeply arrays and objects may nest before the text is refused.")

(defconstant +replacement+ (code-char #xFFFD))

(defun parse-json (string &key (start 0) (end (length string)) trailing)
  "Return the JSON value in STRING between START and END.
Whitespace may surround it; other text after it is an error unless
TRAILING, when the position after the value is returned as a second
value.  Signal `json-error' for anything that is not JSON."
  (declare (type string string) (type fixnum start end))
  (let ((string (coerce string '(simple-array character (*))))
        (position start))
    (declare (type (simple-array character (*)) string) (type fixnum position)
             (optimize (speed 3) (safety 1)))
    (labels ((fail (what)
               (error 'json-error :position position :what what))
             (peek ()
               (if (< position end) (schar string position) (fail "unexpected end")))
             (skip-whitespace ()
               (loop while (and (< position end)
                                (let ((character (schar string position)))
                                  (or (char= character #\Space) (char= character #\Tab)
                                      (char= character #\Newline) (char= character #\Return))))
                     do (incf position)))
             (literal (text value)
               (let ((stop (+ position (length text))))
                 (unless (and (<= stop end) (string= text string :start2 position :end2 stop))
                   (fail "unknown literal"))
                 (setf position stop)
                 value))
             (value (depth)
               (declare (type fixnum depth))
               (when (> depth +max-depth+) (fail "nested too deeply"))
               (skip-whitespace)
               (let ((character (peek)))
                 (case character
                   (#\{ (incf position) (object (1+ depth)))
                   (#\[ (incf position) (array (1+ depth)))
                   (#\" (incf position) (string-value))
                   (#\t (literal "true" t))
                   (#\f (literal "false" nil))
                   (#\n (literal "null" nil))
                   (t (if (or (char= character #\-) (digit-char-p character))
                          (number)
                          (fail "no value starts here"))))))
             (array (depth)
               (skip-whitespace)
               (if (char= (peek) #\])
                   (progn (incf position) '())
                   (let ((items '()))
                     (loop
                       (push (value depth) items)
                       (skip-whitespace)
                       (case (peek)
                         (#\, (incf position))
                         (#\] (incf position) (return (nreverse items)))
                         (t (fail "expected , or ]")))))))
             (object (depth)
               (skip-whitespace)
               (if (char= (peek) #\})
                   (progn (incf position) (make-json-object '()))
                   (let ((pairs '()))
                     (loop
                       (skip-whitespace)
                       (unless (char= (peek) #\") (fail "expected a member name"))
                       (incf position)
                       (let ((name (string-value)))
                         (skip-whitespace)
                         (unless (char= (peek) #\:) (fail "expected :"))
                         (incf position)
                         (push (cons name (value depth)) pairs))
                       (skip-whitespace)
                       (case (peek)
                         (#\, (incf position))
                         (#\} (incf position) (return (make-json-object (nreverse pairs))))
                         (t (fail "expected , or }")))))))
             (string-value ()
               ;; Most strings have no escape: take them whole.
               (let ((stop (position-if (lambda (character)
                                          (or (char= character #\") (char= character #\\)
                                              (char< character #\Space)))
                                        string :start position :end end)))
                 (when (and stop (char= (schar string stop) #\"))
                   (return-from string-value
                     (prog1 (subseq string position stop) (setf position (1+ stop))))))
               (let ((output (make-string-output-stream)))
                 (loop
                   (let ((character (peek)))
                     (incf position)
                     (cond ((char= character #\") (return (get-output-stream-string output)))
                           ((char< character #\Space) (fail "control character in a string"))
                           ((char= character #\\) (write-char (escape) output))
                           (t (write-char character output)))))))
             (escape ()
               (let ((character (peek)))
                 (incf position)
                 (case character
                   (#\" #\") (#\\ #\\) (#\/ #\/)
                   (#\b (code-char 8)) (#\f #\Page) (#\n #\Newline)
                   (#\r #\Return) (#\t #\Tab)
                   (#\u (let ((code (hex4)))
                          (cond ((<= #xD800 code #xDBFF)
                                 ;; A high surrogate pairs with a low one, or stands alone.
                                 (if (and (< (+ position 1) end)
                                          (char= (schar string position) #\\)
                                          (char= (schar string (1+ position)) #\u))
                                     (let ((mark position))
                                       (incf position 2)
                                       (let ((low (hex4)))
                                         (if (<= #xDC00 low #xDFFF)
                                             (code-char (+ #x10000 (ash (- code #xD800) 10) (- low #xDC00)))
                                             (progn (setf position mark) +replacement+))))
                                     +replacement+))
                                ((<= #xDC00 code #xDFFF) +replacement+)
                                (t (code-char code)))))
                   (t (fail "unknown escape")))))
             (hex4 ()
               (unless (<= (+ position 4) end) (fail "short \\u escape"))
               (let ((code 0))
                 (declare (type fixnum code))
                 (dotimes (i 4)
                   (let ((digit (digit-char-p (schar string position) 16)))
                     (unless digit (fail "bad \\u escape"))
                     (setf code (+ (* code 16) digit))
                     (incf position)))
                 code))
             (digits ()
               (let ((first position))
                 (loop while (and (< position end) (digit-char-p (schar string position)))
                       do (incf position))
                 (when (= first position) (fail "expected a digit"))))
             (number ()
               (let ((first position))
                 (when (char= (peek) #\-) (incf position))
                 (if (char= (peek) #\0)
                     (incf position)
                     (digits))
                 (when (and (< position end) (char= (schar string position) #\.))
                   (incf position)
                   (digits))
                 (when (and (< position end) (char-equal (schar string position) #\e))
                   (incf position)
                   (when (and (< position end) (find (schar string position) "+-"))
                     (incf position))
                   (digits))
                 (make-json-number (subseq string first position)))))
      (let ((result (value 0)))
        (if trailing
            (values result position)
            (progn
              (skip-whitespace)
              (unless (= position end) (fail "text after the value"))
              result))))))
