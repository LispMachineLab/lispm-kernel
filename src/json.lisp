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

;;; Strict JSON (RFC 8259), read the way lispm-agent reads it in Emacs,
;;; `json-parse-string' with :null-object and :false-object nil and lists
;;; for arrays:
;;;
;;;   JSON    {"a": 1}   [1, 2]   "x"   true   false   null   1.5
;;;   Lisp    object     (1 2)    "x"   T      NIL     NIL    number
;;;
;;; What Emacs refuses is refused here too, so that a line it skips is
;;; skipped here: a surrogate escape that is not half of a pair, a number
;;; that rounds to infinity as a double, nesting deeper than 10001.  An
;;; object keeps its members in order and `json-get' finds the first of a
;;; name.  Numbers keep their text: what is read here never computes with
;;; them, only asks whether they are there.

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

(declaim (type fixnum *max-depth*)
         (ftype (function (t string) t) json-get)
         (ftype (function (string &key (:start fixnum) (:end fixnum) (:trailing t))
                          (values t &optional fixnum))
                parse-json))

(defun json-get (object name)
  "Return the value of the first member NAME of OBJECT, or nil.
OBJECT may be any value: what is no object has no members."
  (when (json-object-p object)
    (cdr (assoc name (json-object-pairs object) :test #'string=))))

(defparameter *max-depth* 10001
  "How deeply arrays and objects may nest, as Emacs's parser allows.")

(defconstant +double-overflow+
  (+ (rational most-positive-double-float) (expt 2 970))
  "The least magnitude that rounds to infinity as a double.")

(declaim (inline ascii-digit-p hex-digit-value json-fail))

(defun json-fail (position what)
  (declare (type fixnum position))
  (error 'json-error :position position :what what))

(defun ascii-digit-p (character)
  (char<= #\0 character #\9))

(defun hex-digit-value (character)
  (cond ((char<= #\0 character #\9) (- (char-code character) 48))
        ((char<= #\a character #\f) (- (char-code character) 87))
        ((char<= #\A character #\F) (- (char-code character) 55))))

(defun overflows-double-p (text)
  "Return true when the JSON number TEXT, a fraction or an exponent, rounds
to infinity as a double."
  (let* ((e (position-if (lambda (character) (char-equal character #\e)) text))
         (mantissa (subseq text 0 (or e (length text))))
         (exponent (if e (parse-integer text :start (1+ e)) 0))
         (dot (position #\. mantissa))
         (digits (remove #\. (string-left-trim "-" mantissa)))
         (scale (- exponent (if dot (- (length mantissa) dot 1) 0)))
         (significant (string-left-trim "0" digits)))
    (cond ((string= significant "") nil)
          ;; Its leading digit's place, roughly: far from the boundary either way.
          ((> (+ scale (length significant)) 310) t)
          ((< (+ scale (length significant)) 300) nil)
          (t (>= (* (parse-integer significant) (expt 10 scale)) +double-overflow+)))))

(defun parse-json-hex4 (string position end)
  "Read 4 hexadecimal digits from STRING at POSITION below END."
  (declare (type (simple-array character (*)) string)
           (type fixnum position end)
           (optimize (speed 3) (safety 1)))
  (unless (<= (+ position 4) end)
    (json-fail position "short \\u escape"))
  (let ((code 0))
    (declare (type (unsigned-byte 16) code))
    (dotimes (i 4)
      (let ((digit (hex-digit-value (schar string position))))
        (unless digit (json-fail position "bad \\u escape"))
        (setf code (logior (the (unsigned-byte 16) (ash code 4))
                           (the (unsigned-byte 4) digit)))
        (incf position)))
    (values code position)))

(defun parse-json-escape (string position end)
  "Read one JSON string escape starting at POSITION (after #\\\\) below END."
  (declare (type (simple-array character (*)) string)
           (type fixnum position end)
           (optimize (speed 3) (safety 1)))
  (when (>= position end)
    (json-fail position "unexpected end"))
  (let ((character (schar string position)))
    (incf position)
    (case character
      (#\" (values #\" position))
      (#\\ (values #\\ position))
      (#\/ (values #\/ position))
      (#\b (values (code-char 8) position))
      (#\f (values #\Page position))
      (#\n (values #\Newline position))
      (#\r (values #\Return position))
      (#\t (values #\Tab position))
      (#\u (multiple-value-bind (code next) (parse-json-hex4 string position end)
             (declare (type (unsigned-byte 16) code) (type fixnum next))
             (cond ((<= #xD800 code #xDBFF)
                    ;; A high surrogate is half of a pair, or refused.
                    (unless (and (< (1+ next) end)
                                 (char= (schar string next) #\\)
                                 (char= (schar string (1+ next)) #\u))
                      (json-fail next "invalid surrogate"))
                    (multiple-value-bind (low after) (parse-json-hex4 string (+ next 2) end)
                      (declare (type (unsigned-byte 16) low) (type fixnum after))
                      (unless (<= #xDC00 low #xDFFF)
                        (json-fail after "invalid surrogate"))
                      (values (code-char (+ #x10000 (ash (- code #xD800) 10) (- low #xDC00)))
                              after)))
                   ((<= #xDC00 code #xDFFF) (json-fail next "invalid surrogate"))
                   (t (values (code-char code) next)))))
      (t (json-fail position "unknown escape")))))

(defun parse-json-string (string position end)
  "Read a JSON string body starting after the opening quote at POSITION."
  (declare (type (simple-array character (*)) string)
           (type fixnum position end)
           (optimize (speed 3) (safety 1)))
  ;; Most strings have no escape: take them whole.
  (let ((stop (position-if (lambda (character)
                             (or (char= character #\") (char= character #\\)
                                 (char< character #\Space)))
                           string :start position :end end)))
    (when (and stop (char= (schar string stop) #\"))
      (return-from parse-json-string
        (values (subseq string position stop) (1+ stop)))))
  (let ((output (make-string-output-stream)))
    (loop
      (when (>= position end)
        (json-fail position "unexpected end"))
      (let ((character (schar string position)))
        (incf position)
        (cond ((char= character #\")
               (return (values (get-output-stream-string output) position)))
              ((char< character #\Space)
               (json-fail (1- position) "control character in a string"))
              ((char= character #\\)
               (multiple-value-bind (escaped next) (parse-json-escape string position end)
                 (setf position next)
                 (write-char escaped output)))
              (t (write-char character output)))))))

(defun parse-json-number (string position end)
  "Read a JSON number starting at POSITION below END."
  (declare (type (simple-array character (*)) string)
           (type fixnum position end)
           (optimize (speed 3) (safety 1)))
  (let ((first position)
        (integral t))
    (flet ((digits ()
             (let ((start position))
               (loop while (and (< position end) (ascii-digit-p (schar string position)))
                     do (incf position))
               (when (= start position)
                 (json-fail position "expected a digit")))))
      (when (and (< position end) (char= (schar string position) #\-))
        (incf position))
      (when (>= position end)
        (json-fail position "unexpected end"))
      (if (char= (schar string position) #\0)
          (incf position)
          (digits))
      (when (and (< position end) (char= (schar string position) #\.))
        (setf integral nil)
        (incf position)
        (digits))
      (when (and (< position end) (char-equal (schar string position) #\e))
        (setf integral nil)
        (incf position)
        (when (and (< position end) (find (schar string position) "+-"))
          (incf position))
        (digits))
      (let ((text (subseq string first position)))
        ;; An integer of any size is one; a double can overflow.
        (when (and (not integral) (overflows-double-p text))
          (json-fail position "number out of range"))
        (values (make-json-number text) position)))))

(defun parse-json (string &key (start 0) (end (length string)) trailing)
  "Return the JSON value in STRING between START and END.
Whitespace may surround it; other text after it is an error unless
TRAILING, when the position after the value is returned as a second
value.  Signal `json-error' for anything that is not JSON, or that Emacs
refuses."
  (declare (type string string) (type fixnum start end))
  (let ((string (coerce string '(simple-array character (*))))
        (position start)
        (max-depth *max-depth*))
    (declare (type (simple-array character (*)) string)
             (type fixnum position max-depth)
             (optimize (speed 3) (safety 1)))
    (labels ((fail (what)
               (json-fail position what))
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
             (read-str ()
               (multiple-value-bind (val next) (parse-json-string string position end)
                 (setf position next)
                 val))
             (value (depth)
               (declare (type fixnum depth))
               (skip-whitespace)
               (let ((character (peek)))
                 (case character
                   (#\{ (incf position) (object (the fixnum (1+ depth))))
                   (#\[ (incf position) (array (the fixnum (1+ depth))))
                   (#\" (incf position) (read-str))
                   (#\t (literal "true" t))
                   (#\f (literal "false" nil))
                   (#\n (literal "null" nil))
                   (t (if (or (char= character #\-) (ascii-digit-p character))
                          (multiple-value-bind (num next) (parse-json-number string position end)
                            (setf position next)
                            num)
                          (fail "no value starts here"))))))
             (array (depth)
               (declare (type fixnum depth))
               (when (> depth max-depth) (fail "nested too deeply"))
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
               (declare (type fixnum depth))
               (when (> depth max-depth) (fail "nested too deeply"))
               (skip-whitespace)
               (if (char= (peek) #\})
                   (progn (incf position) (make-json-object '()))
                   (let ((pairs '()))
                     (loop
                       (skip-whitespace)
                       (unless (char= (peek) #\") (fail "expected a member name"))
                       (incf position)
                       (let ((name (read-str)))
                         (skip-whitespace)
                         (unless (char= (peek) #\:) (fail "expected :"))
                         (incf position)
                         (push (cons name (value depth)) pairs))
                       (skip-whitespace)
                       (case (peek)
                         (#\, (incf position))
                         (#\} (incf position) (return (make-json-object (nreverse pairs))))
                         (t (fail "expected , or }"))))))))
      (let ((result (value 0)))
        (if trailing
            (values result position)
            (progn
              (skip-whitespace)
              (unless (= position end) (fail "text after the value"))
              result))))))
