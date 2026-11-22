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

(defpackage #:lispm-kernel/csp
  (:use #:common-lisp)
  (:documentation "Lock-free CSP channels, cancellation gates, credit sinks and work-helping pools.")
  (:export #:mbox
           #:make-mbox
           #:mbox-p
           #:mbox-send
           #:mbox-recv
           #:mbox-try-recv
           #:mbox-drain
           #:mbox-count
           #:mbox-empty-p
           #:cancel-token
           #:make-cancel-token
           #:cancel-token-p
           #:cancel!
           #:cancelled-p
           #:await-cancel
           #:register-cancel-hook
           #:credit-sink
           #:make-credit-sink
           #:credit-sink-put-control
           #:credit-sink-put-chunk
           #:credit-sink-take
           #:credit-sink-close
           #:credit-sink-waiting
           #:credit-sink-peak
           #:credit-sink-closed-p
           #:work-group
           #:make-work-group
           #:stop-work-group
           #:work-group-map))

(defpackage #:lispm-kernel/wire
  (:use #:common-lisp)
  (:documentation "S-expression wire reader and printer between Emacs and the kernel.")
  (:export #:wire-error
           #:read-message
           #:write-message
           #:message-string))

(defpackage #:lispm-kernel/json
  (:use #:common-lisp)
  (:documentation "Strict RFC 8259 JSON parser matching Emacs's json-parse-string.")
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
  (:documentation "Nanosecond file stamps, directory listing and bounded byte-range reading.")
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
           #:transcript-read
           #:transcript-read-head
           #:transcript-read-tail
           #:transcript-read-stamp
           #:transcript-read-cut
           #:transcript-read-size
           #:transcript-read-covered
           #:read-head-and-tail
           #:read-file-octets
           #:with-regular-file
           #:read-range
           #:octet-lines
           #:native-stat-p))

(defpackage #:lispm-kernel
  (:use #:common-lisp #:lispm-kernel/csp #:lispm-kernel/wire)
  (:documentation "CSP request coordinator, priority worker pools, credit outbox and built-in jobs.")
  (:export #:+protocol+
           #:main
           ;; Structured conditions
           #:kernel-error
           #:message-error
           #:job-error
           #:fetch-error
           #:exec-error
           #:regex-error
           ;; Defining work
           #:define-job
           #:emit
           #:checkpoint
           #:current-cancel-token
           #:parallel-map
           #:*cache-clearers*
           #:*background-stoppers*
           ;; A kernel in this process
           #:start-kernel
           #:stop-kernel
           #:stop-background-helpers
           #:handle-message
           #:handle-line
           #:kernel-stats))

(defpackage #:lispm-kernel/sessions
  (:use #:common-lisp #:lispm-kernel/csp #:lispm-kernel/json #:lispm-kernel/files)
  (:documentation "Parallel discovery and snapshot-isolated caching of Codex and Claude sessions.")
  (:import-from #:lispm-kernel
                #:job-error
                #:define-job
                #:emit
                #:checkpoint
                #:parallel-map
                #:*cache-clearers*
                #:*background-stoppers*)
  (:export #:scan-error
           #:scan
           #:clear-caches
           #:human-text-p
           #:content-text
           #:file-name-base))
