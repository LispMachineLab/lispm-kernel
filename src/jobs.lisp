;;;; jobs.lisp --- Jobs that show the protocol at work

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

;;; Small jobs whose results are known, for Emacs to check the kernel
;;; with: what goes there comes back, chunks come before the result, and
;;; cancellation, timeouts and failures end a request as they should.

(in-package #:lispm-kernel)

(define-job (echo) (input)
  "Return INPUT as it came."
  input)

(define-job (wait :class :io) (input)
  "Emit CHUNKS chunks, 0, 1 and so on, then wait MILLISECONDS, stopping
when cancelled; then fail with FAIL, a string, when given, else return
MILLISECONDS.  INPUT is a plist of them."
  (destructuring-bind (&key (chunks 0) (milliseconds 0) fail) input
    (check-type chunks (integer 0 100000))
    (check-type milliseconds (integer 0 3600000))
    (dotimes (index chunks)
      (emit index))
    (let ((deadline (+ (get-internal-real-time)
                       (floor (* milliseconds internal-time-units-per-second) 1000))))
      (loop while (< (get-internal-real-time) deadline)
            do (checkpoint)
               (sleep 0.002)))
    (when fail
      (error "~A" fail))
    milliseconds))
