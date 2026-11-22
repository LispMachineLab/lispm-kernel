;;;; wire.lisp --- The S-expressions between Emacs and the kernel

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

;;; Each message is one datum on one line, in Emacs Lisp's syntax, so that
;;; Emacs reads what the kernel prints with its own `read' and the kernel
;;; reads what Emacs prints with `prin1', newlines and control characters
;;; escaped.  Only data cross: integers, strings, symbols, lists and
;;; vectors.  The kernel's reader is not CL's: it reads Emacs's string
;;; escapes, interns nothing but keywords, and evaluates nothing.
;;;
;;;   Emacs   foo  :foo  nil  t  12  "a\nb"  (1 2)  [1 2]
;;;   kernel  :FOO :FOO  NIL  T  12  "a
;;;                                   b"           (1 2)  #(1 2)
;;;
;;; Printing goes the other way: a keyword prints as :name, any other
;;; symbol as its name, both in lower case, so the kernel's own words
;;; (DONE, SUCCESS) reach Emacs as plain symbols.

(in-package #:lispm-kernel/wire)

(define-condition wire-error (error)
  ((message :initarg :message :reader wire-error-message))
  (:report (lambda (condition stream)
             (write-string (wire-error-message condition) stream)))
  (:documentation "A message that is not one datum of the wire's syntax."))

(defun wire-error (control &rest arguments)
  (error 'wire-error :message (apply #'format nil control arguments)))

(defconstant +max-depth+ 64
  "How deeply lists and vectors of one message may nest.")

(defconstant +max-symbol-length+ 256)

(defconstant +replacement+ (code-char #xFFFD)
  "What stands for a character the other side cannot have.")

;;;; Reading

(declaim (inline delimiterp whitespacep)
         (ftype (function (string) t) read-message)
         (ftype (function (t stream) t) write-message)
         (ftype (function (t) string) message-string))

(defun whitespacep (character)
  (member character '(#\Space #\Tab #\Return #\Page #\Newline)))

(defun delimiterp (character)
  (or (whitespacep character)
      (member character '(#\( #\) #\[ #\] #\" #\; #\' #\` #\, #\#))))

(defun digit-value (character radix)
  (and character (digit-char-p character radix)))

(defun integer-token-p (token)
  (let ((start (if (and (> (length token) 1) (find (char token 0) "+-")) 1 0)))
    (and (< start (length token))
         (every #'digit-char-p (subseq token start)))))

(defun float-token-p (token)
  (and (some #'digit-char-p token)
       (every (lambda (character) (or (digit-char-p character) (find character "+-.eE")))
              token)))

(defun decode-code-point (code)
  "Return the character for CODE, or `+replacement+' when invalid or surrogate."
  (if (or (>= code char-code-limit) (<= #xD800 code #xDFFF))
      +replacement+
      (code-char code)))

(defun decode-control-char (character)
  "Return the control character denoted by \\^CHARACTER."
  (if (char= character #\?)
      (code-char 127)
      (code-char (logand (char-code character) 31))))

(defun parse-token-datum (token)
  "Convert wire token string TOKEN into an integer, nil, t, or keyword."
  (cond ((integer-token-p token) (parse-integer token))
        ((float-token-p token)
         (wire-error "~A: numbers other than integers are no syntax of the wire" token))
        ((> (length token) +max-symbol-length+)
         (wire-error "A symbol is longer than ~D characters" +max-symbol-length+))
        ((string= token "nil") nil)
        ((string= token "t") t)
        ((and (> (length token) 1) (char= (char token 0) #\:))
         (intern (string-upcase (subseq token 1)) :keyword))
        (t (intern (string-upcase token) :keyword))))

(defun read-string-escape (next-fn peek-fn position-fn)
  "Read one backslash escape from a wire string using NEXT-FN, PEEK-FN and POSITION-FN."
  (flet ((hex-digits (count)
           (let ((code 0) (digits 0))
             (loop while (and (or (null count) (< digits count))
                              (digit-value (funcall peek-fn) 16))
                   do (setf code (+ (* code 16) (digit-value (funcall next-fn) 16)))
                      (incf digits))
             (when (or (zerop digits) (and count (/= digits count)))
               (wire-error "A hexadecimal escape lacks its digits at ~D" (funcall position-fn)))
             code)))
    ;; Emacs's escapes in strings; nil for those that stand for nothing.
    (let ((character (funcall next-fn)))
      (case character
        (#\n #\Newline)
        (#\t #\Tab)
        (#\r #\Return)
        (#\f #\Page)
        (#\e (code-char 27))
        (#\a (code-char 7))
        (#\b (code-char 8))
        (#\v (code-char 11))
        (#\d (code-char 127))
        (#\s #\Space)
        ((#\Newline #\Space) nil)
        (#\x (decode-code-point (hex-digits nil)))
        (#\u (decode-code-point (hex-digits 4)))
        (#\U (decode-code-point (hex-digits 8)))
        (#\^ (decode-control-char (funcall next-fn)))
        ((#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7)
         (let ((code (digit-char-p character 8)))
           (loop repeat 2
                 while (digit-value (funcall peek-fn) 8)
                 do (setf code (+ (* code 8) (digit-value (funcall next-fn) 8))))
           ;; Above 127, Emacs means a raw byte, which no character is.
           (if (< code 128) (code-char code) +replacement+)))
        ((#\C #\M #\S #\H #\A #\N)
         (wire-error "The escape \\~C is no syntax of the wire" character))
        (t character)))))

(defun read-message (string)
  "Return the one datum STRING holds, as Emacs's `prin1' printed it.
Signal `wire-error' when STRING holds anything else."
  (declare (type string string))
  (let ((position 0)
        (end (length string)))
    (labels ((pos () position)
             (peek ()
               (and (< position end) (char string position)))
             (next ()
               (when (>= position end)
                 (wire-error "The message ends inside a datum"))
               (prog1 (char string position) (incf position)))
             (skip-whitespace ()
               (loop while (and (< position end) (whitespacep (char string position)))
                     do (incf position)))
             (datum (depth)
               (when (> depth +max-depth+)
                 (wire-error "The message nests deeper than ~D" +max-depth+))
               (skip-whitespace)
               (let ((character (peek)))
                 (case character
                   ((nil) (wire-error "The message ends where a datum should be"))
                   (#\( (incf position) (sequence-of #\) depth))
                   (#\[ (incf position) (coerce (sequence-of #\] depth) 'simple-vector))
                   (#\" (incf position) (string-datum))
                   ((#\) #\]) (wire-error "Unexpected ~C at ~D" character position))
                   (t (if (delimiterp character)
                          (wire-error "~C is no syntax of the wire, at ~D" character position)
                          (token))))))
             (sequence-of (closing depth)
               (let ((items '()))
                 (loop
                   (skip-whitespace)
                   (let ((character (peek)))
                     (cond ((null character)
                            (wire-error "The message ends before ~C" closing))
                           ((char= character closing)
                            (incf position)
                            (return (nreverse items)))
                           ((char= character #\.)
                            (wire-error "Dotted pairs are no syntax of the wire"))
                           (t (push (datum (1+ depth)) items)))))))
             (string-datum ()
               (let ((output (make-string-output-stream)))
                 (loop
                   (let ((character (next)))
                     (case character
                       (#\" (return (get-output-stream-string output)))
                       (#\\ (let ((escaped (read-string-escape #'next #'peek #'pos)))
                              (when escaped (write-char escaped output))))
                       (t (write-char character output)))))))
             (token ()
               (let ((start position))
                 (loop while (and (< position end) (not (delimiterp (char string position))))
                       do (when (char= (char string position) #\\)
                            (wire-error "Escaped symbols are no syntax of the wire"))
                          (incf position))
                 (parse-token-datum (subseq string start position)))))
      (let ((datum (datum 0)))
        (skip-whitespace)
        (when (< position end)
          (wire-error "Text follows the message at ~D" position))
        datum))))

;;;; Printing

(defun write-message (datum stream)
  "Print DATUM to STREAM so that Emacs's `read' reads it back, on one line.
Signal `wire-error' for what Emacs cannot read so."
  (write-datum datum stream 0)
  datum)

(defun message-string (datum)
  "Return DATUM printed for Emacs, see `write-message'."
  (with-output-to-string (stream)
    (write-message datum stream)))

(defun write-datum (datum stream depth)
  (when (> depth +max-depth+)
    (wire-error "The datum nests deeper than ~D" +max-depth+))
  (typecase datum
    (null (write-string "nil" stream))
    ((eql t) (write-string "t" stream))
    (keyword (write-char #\: stream) (write-symbol-name datum stream))
    (symbol (write-symbol-name datum stream))
    (integer (let ((*print-base* 10) (*print-radix* nil))
               (princ datum stream)))
    (string (write-string-datum datum stream))
    (cons (write-char #\( stream)
          (loop for (item . rest) on datum
                do (write-datum item stream (1+ depth))
                   (typecase rest
                     (null)
                     (cons (write-char #\Space stream))
                     (t (write-string " . " stream)
                        (write-datum rest stream (1+ depth)))))
          (write-char #\) stream))
    (vector (write-char #\[ stream)
            (loop for item across datum
                  for first = t then nil
                  do (unless first (write-char #\Space stream))
                     (write-datum item stream (1+ depth)))
            (write-char #\] stream))
    (t (wire-error "A ~S cannot be sent to Emacs" (type-of datum)))))

(defun write-symbol-name (symbol stream)
  (let ((name (string-downcase (symbol-name symbol))))
    (unless (and (plusp (length name))
                 (every (lambda (character)
                          (or (char<= #\a character #\z) (digit-char-p character)
                              (find character "-_/*+<>=!?")))
                        name))
      (wire-error "The symbol ~S cannot be sent to Emacs as it is" symbol))
    (write-string name stream)))

(defun write-string-datum (string stream)
  (write-char #\" stream)
  (loop for index from 0 below (length string)
        for character = (char string index)
        for code = (char-code character)
        do (cond ((char= character #\") (write-string "\\\"" stream))
                 ((char= character #\\) (write-string "\\\\" stream))
                 ((char= character #\Newline) (write-string "\\n" stream))
                 ((char= character #\Return) (write-string "\\r" stream))
                 ((char= character #\Page) (write-string "\\f" stream))
                 ((char= character #\Tab) (write-char character stream))
                 ;; Three digits always, so a digit after one is not read into it.
                 ((< code 32) (format stream "\\~3,'0O" code))
                 ((<= #xD800 code #xDFFF) (write-char +replacement+ stream))
                 (t (write-char character stream))))
  (write-char #\" stream))
