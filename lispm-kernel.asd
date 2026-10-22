;;;; lispm-kernel.asd --- The LispM kernel, a Lisp beside Emacs

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

(defsystem "lispm-kernel"
  :description "LispM's kernel: work Emacs should not wait on, done on threads of a Lisp of its own"
  :author "Ryan.K"
  :license "AGPL-3.0-or-later"
  :depends-on ((:require "sb-posix"))
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "wire")
               (:file "json")
               (:file "files")
               (:file "runtime")
               (:file "jobs")
               (:file "fetch")
               (:file "sessions")
               (:file "main"))
  :in-order-to ((test-op (test-op "lispm-kernel/test"))))

(defsystem "lispm-kernel/test"
  :description "Tests of the LispM kernel"
  :author "Ryan.K"
  :license "AGPL-3.0-or-later"
  :depends-on ("lispm-kernel")
  :pathname "test/"
  :serial t
  :components ((:file "harness")
               (:file "wire-test")
               (:file "json-test")
               (:file "files-test")
               (:file "runtime-test")
               (:file "sessions-test")
               (:file "fetch-test"))
  :perform (test-op (operation component)
             (unless (uiop:symbol-call :lispm-kernel/test :run-tests)
               (error "The kernel's tests failed"))))
