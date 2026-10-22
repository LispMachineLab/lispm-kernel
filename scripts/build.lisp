;;;; build.lisp --- Build the kernel program

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

;;; sbcl --non-interactive --no-sysinit --no-userinit --load scripts/build.lisp
;;;
;;; Compiles the kernel afresh, any warning failing the build, and saves
;;; it as one executable, SBCL's runtime and the kernel's core together,
;;; at $LISPM_KERNEL_OUTPUT, by default build/lispm-kernel in the
;;; repository.  It runs on a computer without SBCL.  With
;;; LISPM_KERNEL_TEST set, the kernel's tests run first, and fail the
;;; build when one fails.

(require :asdf)

(defvar *root* (uiop:pathname-parent-directory-pathname
                (uiop:pathname-directory-pathname *load-truename*)))

(push *root* asdf:*central-registry*)

(handler-bind ((warning (lambda (condition)
                          ;; Loading what was just compiled redefines its macros.
                          (unless (typep condition 'sb-kernel:redefinition-warning)
                            (format *error-output* "~&Warning, so no build: ~A~%" condition)
                            (uiop:quit 1)))))
  (asdf:load-system "lispm-kernel" :force t))

(when (uiop:getenv "LISPM_KERNEL_TEST")
  (asdf:load-system "lispm-kernel/test")
  (unless (uiop:symbol-call :lispm-kernel/test :run-tests)
    (uiop:quit 1)))

(let ((output (or (uiop:getenv "LISPM_KERNEL_OUTPUT")
                  (uiop:native-namestring (merge-pathnames "build/lispm-kernel" *root*)))))
  (ensure-directories-exist (uiop:parse-native-namestring output))
  (format t "~&Saving the kernel as ~A~%" output)
  (sb-ext:save-lisp-and-die output :executable t
                                   :toplevel #'lispm-kernel:main
                                   :save-runtime-options t))
