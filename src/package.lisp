;;;; package.lisp --- The kernel's packages

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

;;; The kernel is a Common Lisp process that Emacs starts and talks to in
;;; S-expressions, one per line, over the process's standard input and
;;; output.  Emacs asks for work; the kernel does it on threads of its
;;; own and answers with chunks and one final word for each request.
;;;
;;;   wire      the S-expressions both sides read and print
;;;   json      JSON, as agents write their transcripts
;;;   files     stat with nanoseconds, directories, byte ranges
;;;   kernel    requests, worker pools, the outbox, the protocol, downloads,
;;;             programs
;;;   sessions  the agents' sessions, read from their transcripts

(defpackage #:lispm-kernel/wire
  (:use #:common-lisp)
  (:export #:wire-error
           #:read-message
           #:write-message
           #:message-string))

(defpackage #:lispm-kernel/json
  (:use #:common-lisp)
  (:export #:json-error
           #:parse-json
           #:json-object
           #:json-object-p
           #:json-object-pairs
           #:json-number
           #:json-number-p
           #:json-number-text
           #:json-get))

(defpackage #:lispm-kernel/files
  (:use #:common-lisp)
  (:export #:stamp
           #:stamp-p
           #:stamp-kind
           #:stamp-size
           #:stamp-mtime
           #:stamp-ctime
           #:stamp-inode
           #:stamp-device
           #:stamp=
           #:file-stamp
           #:directory-names
           #:read-head-and-tail
           #:read-file-octets
           #:octet-lines
           #:native-stat-p))

(defpackage #:lispm-kernel
  (:use #:common-lisp #:lispm-kernel/wire)
  (:export #:+protocol+
           #:main
           ;; Defining work
           #:define-job
           #:emit
           #:checkpoint
           #:parallel-map
           #:*cache-clearers*
           ;; A kernel in this process
           #:start-kernel
           #:stop-kernel
           #:handle-message
           #:handle-line
           #:kernel-stats))

(defpackage #:lispm-kernel/sessions
  (:use #:common-lisp #:lispm-kernel/json #:lispm-kernel/files)
  (:import-from #:lispm-kernel
                #:define-job
                #:emit
                #:checkpoint
                #:parallel-map
                #:*cache-clearers*)
  (:export #:scan
           #:clear-caches
           #:human-text-p
           #:content-text
           #:file-name-base))
