;;;; json-test.lisp --- Tests of JSON as transcripts have it

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

(deftest json-literals-and-numbers ()
  (is (eq t (parse-json "true")))
  (is (eq nil (parse-json "false")))
  (is (eq nil (parse-json " null ")))
  (is (equal '() (parse-json "[]")))
  (is (string= "-12.5e+3" (json-number-text (parse-json "-12.5e+3"))))
  (is (string= "0" (json-number-text (parse-json "0")))))

(deftest json-strings ()
  (is (string= "plain" (parse-json "\"plain\"")))
  (is (string= (concatenate 'string "a\"b\\c/" (string #\Newline) (string #\Tab) (chars 8 12 13))
               (parse-json "\"a\\\"b\\\\c\\/\\n\\t\\b\\f\\r\"")))
  (is (string= (chars #xE9) (parse-json "\"\\u00e9\"")))
  (is (string= (chars #x1F600) (parse-json "\"\\ud83d\\ude00\"")))
  ;; Surrogates alone are no characters: Emacs refuses them.
  (signals json-error (parse-json "\"\\ud83dA\""))
  (signals json-error (parse-json "\"\\ud83d\\u0041\""))
  (signals json-error (parse-json "\"\\ude00\""))
  (signals json-error (parse-json "\"a\\ud83d\""))
  (is (string= (chars #xE9 #x1F600) (parse-json (concatenate 'string "\"" (chars #xE9 #x1F600) "\"")))))

(deftest json-objects-and-arrays ()
  (let ((object (parse-json "{\"type\": \"user\", \"n\": [1, {\"a\": null}], \"type\": \"later\"}")))
    (is (json-object-p object))
    (is (string= "user" (json-get object "type")))
    (is (eq nil (json-get object "missing")))
    (is (eq nil (json-get (second (json-get object "n")) "a")))
    (is (= 3 (length (json-object-pairs object)))))
  (is (eq nil (json-get "not an object" "type")))
  (is (eq nil (json-get nil "type")))
  (is (equal '("a" ("b")) (parse-json "[\"a\", [\"b\"]]"))))

(deftest json-refuses-what-is-not-json ()
  (dolist (text '("" "tru" "01" "1." "-" ".5" "1e" "[1,]" "{\"a\" 1}" "{\"a\":1,}" "{a:1}"
                  "\"abc" "\"\\x\"" "\"\\u12g4\"" "[1] 2" "'a'" "NaN"))
    (signals json-error (parse-json text)))
  (signals json-error (parse-json (concatenate 'string "\"a" (string #\Newline) "b\"")))
  ;; Only ASCII digits are digits.
  (signals json-error (parse-json (concatenate 'string "[" (chars #x661) "]")))
  (signals json-error (parse-json (concatenate 'string "\"\\u" (chars #x661) "234\""))))

(deftest json-numbers-as-emacs-has-them ()
  ;; A double that rounds to infinity is refused; an integer of any size is one.
  (dolist (text '("1e400" "-1e400" "1.7976931348623159e308" "1.797693134862316e308" "17976931348623159e292"))
    (signals json-error (parse-json text)))
  (dolist (text '("1e-400" "1.7976931348623157e308" "123456789012345678901234567890"
                  "0.0e99999999999" "-0" "2.5E+3"))
    (is (string= text (json-number-text (parse-json text))))))

(defun nested (depth)
  (concatenate 'string (make-string depth :initial-element #\[) (make-string depth :initial-element #\])))

(deftest json-depth-as-emacs-has-it ()
  ;; 10001 levels and no more, read on a thread of its own as a worker does.
  (is (eq :read (sb-thread:join-thread
                 (sb-thread:make-thread (lambda () (parse-json (nested 10001)) :read)))))
  (signals json-error (parse-json (nested 10002)))
  (is (= 3 (length (loop for value = (parse-json (nested 4)) then (first value)
                         while (consp value)
                         collect value)))))

(deftest json-trailing-text ()
  (multiple-value-bind (value end) (parse-json "{\"customTitle\": \"x\"} trailing" :trailing t)
    (is (string= "x" (json-get value "customTitle")))
    (is (= 20 end)))
  (is (eql 3 (nth-value 1 (parse-json "  1 2" :start 0 :trailing t)))))
