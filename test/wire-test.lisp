;;;; wire-test.lisp --- Tests of the wire's S-expressions

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

(deftest wire-reads-atoms ()
  (is (eql 12 (read-message "12")))
  (is (eql -5 (read-message "-5")))
  (is (eql 7 (read-message "+7")))
  (is (eq nil (read-message "nil")))
  (is (eq t (read-message "t")))
  (is (eq :submit (read-message "submit")))
  (is (eq :owner (read-message ":owner")))
  (is (eq :scan-sessions (read-message "  scan-sessions  ")))
  (is (string= "" (read-message "\"\""))))

(deftest wire-reads-what-emacs-prints ()
  ;; As Emacs 31's prin1 prints "a\nb\tc\rd\x01" "2e\x7f f\"g\\h é 😀 \e\f",
  ;; newlines and control characters escaped.
  (is (string= (concatenate 'string "a" (string #\Newline) "b" (string #\Tab) "c" (string #\Return)
                            "d" (chars 1) "2e" (chars 127) " f\"g\\h " (chars #xE9) " "
                            (chars #x1F600) " " (chars 27) (string #\Page))
               (read-message (concatenate 'string "\"a\\nb\\11c\\15d\\0012e\\177 f\\\"g\\\\h "
                                          (chars #xE9) " " (chars #x1F600) " \\33\\f\""))))
  (is (string= (concatenate 'string "AB" (chars #xE9 #x1F600 1) " " (chars 127))
               (read-message "\"\\x41\\ B\\u00e9\\U0001F600\\^A\\s\\d\"")))
  (is (string= "ab" (read-message (format nil "\"a\\~%b\""))))
  ;; Above 127 Emacs means a raw byte, which no character is.
  (is (string= (chars #xFFFD) (read-message "\"\\377\""))))

(deftest wire-reads-lists-and-vectors ()
  (is (equal '(:submit 1 :echo ("x" :k nil) :owner 2)
             (read-message "(submit 1 echo (\"x\" :k nil) :owner 2)")))
  (is (equalp #(1 #(2) (3)) (read-message "[1 [2] (3)]")))
  (is (equal '() (read-message "()"))))

(deftest wire-refuses-what-is-not-data ()
  (signals wire-error (read-message ""))
  (signals wire-error (read-message "1.5"))
  (signals wire-error (read-message "1e3"))
  (signals wire-error (read-message "(1 . 2)"))
  (signals wire-error (read-message "(1 2"))
  (signals wire-error (read-message "(1) 2"))
  (signals wire-error (read-message ")"))
  (signals wire-error (read-message "'a"))
  (signals wire-error (read-message "#s(a)"))
  (signals wire-error (read-message "a\\ b"))
  (signals wire-error (read-message "\"abc"))
  (signals wire-error (read-message "\"\\C-a\""))
  (signals wire-error (read-message "\"\\u12\""))
  (signals wire-error (read-message (make-string 100 :initial-element #\()))
  (signals wire-error (read-message (make-string 300 :initial-element #\a))))

(deftest wire-prints-for-emacs ()
  (is (string= "(done 7 success (:k \"v\" nil t -3 [1 2]))"
               (message-string (list 'lispm-kernel::done 7 'lispm-kernel::success
                                     (list :k "v" nil t -3 #(1 2))))))
  (is (string= "(a . 1)" (message-string (cons 'a 1))))
  (is (string= "\"a\\nb\\rc\\fd\\001\\0012\\\"\\\\\""
               (message-string (concatenate 'string "a" (string #\Newline) "b" (string #\Return) "c"
                                            (string #\Page) "d" (chars 1 1) "2\"\\"))))
  (is (string= (format nil "\"~C\"" #\Tab) (message-string (string #\Tab))))
  (is (string= (concatenate 'string "\"" (chars #xE9 #x1F600) "\"")
               (message-string (chars #xE9 #x1F600))))
  (is (string= (concatenate 'string "\"" (chars #xFFFD) "\"") (message-string (chars #xD800))))
  (is (not (find #\Newline (message-string (list (make-string 10 :initial-element #\Newline)))))))

(deftest wire-refuses-what-emacs-cannot-read ()
  (signals wire-error (message-string 1.5))
  (signals wire-error (message-string (make-hash-table)))
  (signals wire-error (message-string '|a b|))
  (signals wire-error (message-string :|X.Y|)))

(deftest wire-round-trips ()
  (let ((datum (list :id "a\"b\\c"
                     :title (concatenate 'string "x" (string #\Newline) (chars 0 7 31 #xE9))
                     :n -12345678901234567890 :v #(1 "2" nil) :more '(nil t))))
    (is (equalp datum (read-message (message-string datum))))))
