;;; lispm-kernel-test.el --- Real module integration tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-kernel
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is not part of GNU Emacs.

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

(require 'ert)
(require 'cl-lib)
(module-load (or (getenv "LISPM_KERNEL_MODULE") (error "Set LISPM_KERNEL_MODULE to the built module")))
(require 'lispm-kernel)

(defun lispm-kernel-test--submit (runtime text callback &optional generation timeout)
  (let ((deadline (+ (float-time) 3)) request)
    (while (and (not (integerp request)) (< (float-time) deadline))
      (setq request (lispm-kernel-submit runtime 'echo text :owner 7
                                        :generation (or generation 0) :on-result callback
                                        :timeout (or timeout lispm-kernel-request-timeout)))
      (unless (integerp request) (sleep-for 0.001)))
    (should (integerp request)) request))
(defun lispm-kernel-test--finish (runtime)
  (let ((deadline (+ (float-time) 3)))
    (while (and (> (hash-table-count (lispm-kernel-runtime-callbacks runtime)) 0)
                (< (float-time) deadline))
      (lispm-kernel-dispatch runtime)
      (sleep-for 0.001))
    (should (= (hash-table-count (lispm-kernel-runtime-callbacks runtime)) 0))))

(ert-deftest lispm-kernel-roundtrip-utf8 ()
  (let ((runtime (lispm-kernel-create)) result)
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "Lisp Machine λ €" (lambda (event) (setq result event)))
          (lispm-kernel-test--finish runtime)
          (should (eq (aref result 4) 'success))
          (should (equal (aref result 5) "Lisp Machine λ €"))
          (should-not (lispm-kernel-runtime-timer runtime)))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-stale-results-do-not-call-callback ()
  (let ((runtime (lispm-kernel-create)) results)
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "old" (lambda (event) (push event results)))
          (lispm-kernel-supersede runtime 7 1)
          (lispm-kernel-test--submit runtime "new" (lambda (event) (push event results)) 1)
          (lispm-kernel-test--finish runtime)
          (should (= (length results) 1))
          (should (equal (aref (car results) 5) "new")))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-callback-error-does-not-stop-dispatch ()
  (let ((runtime (lispm-kernel-create)) result)
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "bad" (lambda (_) (error "test callback failure")))
          (lispm-kernel-test--submit runtime "good" (lambda (event) (setq result event)))
          (lispm-kernel-test--finish runtime)
          (should result)
          (should (lispm-kernel-runtime-last-error runtime)))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-input-pending-yields-before-draining ()
  (let ((runtime (lispm-kernel-create)) result)
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "test" (lambda (event) (setq result event)))
          (cl-letf (((symbol-function 'input-pending-p) (lambda () t)))
            (lispm-kernel-dispatch runtime))
          (should-not result)
          (should (= (hash-table-count (lispm-kernel-runtime-callbacks runtime)) 1))
          (lispm-kernel-test--finish runtime)
          (should result))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-reports-overrunning-callback ()
  (let ((runtime (lispm-kernel-create))
        (lispm-kernel-slice-seconds 0.001))
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "slow" (lambda (_) (sleep-for 0.01)))
          (lispm-kernel-test--finish runtime)
          (should (> (lispm-kernel-runtime-overruns runtime) 0)))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-shutdown-rejects-more-work ()
  (let ((runtime (lispm-kernel-create)))
    (lispm-kernel-shutdown runtime)
    (lispm-kernel-shutdown runtime)
    (should-error (lispm-kernel-submit runtime 'echo "closed"))))

(ert-deftest lispm-kernel-callbacks-do-not-reenter-dispatch ()
  (let ((runtime (lispm-kernel-create)) active result)
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "first"
            (lambda (_)
              (setq active t)
              (lispm-kernel-dispatch runtime)
              (setq active nil)))
          (lispm-kernel-test--submit runtime "second"
            (lambda (_) (should-not active) (setq result t)))
          (lispm-kernel-test--finish runtime)
          (should result)
          (should-not (lispm-kernel-runtime-last-error runtime)))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-oversized-input-is-rejected ()
  (let ((runtime (lispm-kernel-create)))
    (unwind-protect
        (progn
          (should (eq (lispm-kernel-submit runtime 'echo (make-string 65536 ?a)) 'too-large))
          (should-not (lispm-kernel-runtime-timer runtime)))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-real-session-scan-streams-json ()
  (let* ((runtime (lispm-kernel-create))
         (directory (make-temp-file "lispm-scan-" t))
         rows summary request)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "rollout-test.jsonl" directory)
            (insert "{\"type\":\"session_meta\",\"payload\":{\"id\":\"test-id\",\"cwd\":\"/test\"}}\n"
                    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Grüße € kernel\"}}\n"))
          (let ((deadline (+ (float-time) 3)))
            (while (and (not (integerp request)) (< (float-time) deadline))
              (setq request (lispm-kernel-submit runtime 'codex-scan directory :owner 8
                :on-result (lambda (event)
                  (pcase (aref event 4)
                    ('chunk (push (json-parse-string (aref event 5) :object-type 'plist) rows))
                    ('success (setq summary (json-parse-string (aref event 5) :object-type 'plist)))
                    (_ (ert-fail (format "Scan failed: %S" event)))))))
              (unless (integerp request) (sleep-for 0.001))))
          (should (integerp request))
          (lispm-kernel-test--finish runtime)
          (should (= (length rows) 1))
          (should (equal (plist-get (car rows) :title) "Grüße € kernel"))
          (should (= (plist-get summary :rows) 1))
          (should (= (plist-get summary :errors) 0)))
      (lispm-kernel-shutdown runtime)
      (delete-directory directory t))))

(require 'lispm-kernel-sessions)
(ert-deftest lispm-kernel-session-api-falls-back-without-module-runtime ()
  (let (result summary)
    (lispm-kernel-scan-sessions nil 'codex "/unused"
      (lambda (rows details) (setq result rows summary details))
      :fallback (lambda () '((:id "fallback"))))
    (let ((deadline (+ (float-time) 3)))
      (while (and (null result) (< (float-time) deadline)) (sleep-for 0.001)))
    (should (equal result '((:id "fallback"))))
    (should (eq (plist-get summary :source) 'elisp))))

(ert-deftest lispm-kernel-session-api-converts-real-rows ()
  (let* ((runtime (lispm-kernel-create)) (directory (make-temp-file "lispm-scan-api-" t)) rows summary)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "rollout-test.jsonl" directory)
            (insert "{\"type\":\"session_meta\",\"payload\":{\"id\":\"id\",\"cwd\":\"/test\",\"timestamp\":\"2026-10-21T00:00:00Z\"}}\n"
                    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"hello\"}}\n"))
          (let (request (deadline (+ (float-time) 3)))
            (while (and (not (integerp request)) (< (float-time) deadline))
              (setq request (lispm-kernel-scan-sessions runtime 'codex directory
                               (lambda (result details) (setq rows result summary details))))
              (unless (integerp request) (sleep-for 0.001)))
            (should (integerp request)))
          (lispm-kernel-test--finish runtime)
          (should (= (length rows) 1))
          (should (eq (plist-get (car rows) :agent) 'codex))
          (should (numberp (plist-get (car rows) :started)))
          (should (= (plist-get summary :errors) 0)))
      (lispm-kernel-shutdown runtime) (delete-directory directory t))))

(ert-deftest lispm-kernel-incompatible-protocol-falls-back ()
  (cl-letf (((symbol-function 'lispm-kernel-module-protocol-version) (lambda () 999)))
    (should-not (lispm-kernel-try-create nil))
    (should lispm-kernel-module-error)))

(ert-deftest lispm-kernel-native-scan-failure-uses-explicit-fallback ()
  (let ((runtime (lispm-kernel-create)) rows details request)
    (unwind-protect
        (progn
          (let ((deadline (+ (float-time) 3)))
            (while (and (not (integerp request)) (< (float-time) deadline))
              (setq request (lispm-kernel-scan-sessions runtime 'codex "/no-such-lispm-scan-fixture"
                              (lambda (result summary) (setq rows result details summary))
                              :fallback (lambda () '((:id "fallback-after-failure")))))
              (unless (integerp request) (sleep-for 0.001))))
          (should (integerp request))
          (lispm-kernel-test--finish runtime)
          (let ((deadline (+ (float-time) 3)))
            (while (and (null details) (< (float-time) deadline)) (sleep-for 0.001)))
          (should (equal rows '((:id "fallback-after-failure"))))
          (should (eq (plist-get details :source) 'elisp)))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-session-limit-cancels-incomplete-collection ()
  (let* ((runtime (lispm-kernel-create)) (directory (make-temp-file "lispm-limit-" t)) rows details request)
    (unwind-protect
        (progn
          (dotimes (index 4)
            (with-temp-file (expand-file-name (format "rollout-%d.jsonl" index) directory)
              (insert (format "{\"type\":\"session_meta\",\"payload\":{\"id\":\"%d\",\"cwd\":\"/test\"}}\n" index)
                      "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"hello\"}}\n")))
          (let ((deadline (+ (float-time) 3)))
            (while (and (not (integerp request)) (< (float-time) deadline))
              (setq request (lispm-kernel-scan-sessions runtime 'codex directory
                              (lambda (result summary) (setq rows result details summary)) :max-sessions 1))
              (unless (integerp request) (sleep-for 0.001))))
          (lispm-kernel-test--finish runtime)
          (should-not rows)
          (should (eq (plist-get details :error) 'session-limit)))
      (lispm-kernel-shutdown runtime) (delete-directory directory t))))

(ert-deftest lispm-kernel-timeout-ends-request-once ()
  (let ((runtime (lispm-kernel-create)) kinds)
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "late" (lambda (event) (push (aref event 4) kinds)) 0 -1)
          (lispm-kernel--expire runtime)
          (should (equal kinds '(timeout)))
          (should-not (lispm-kernel-pending-p runtime))
          ;; The native outcome arriving afterwards finds no callback.
          (sleep-for 0.05)
          (lispm-kernel-dispatch runtime)
          (should (equal kinds '(timeout))))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-persistent-drain-error-ends-requests-as-lost ()
  (let ((runtime (lispm-kernel-create)) kinds)
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "x" (lambda (event) (push (aref event 4) kinds)))
          (cl-letf (((symbol-function 'lispm-kernel-module-drain) (lambda (&rest _) 'kernel-error)))
            (lispm-kernel-dispatch runtime))
          (should (equal kinds '(lost)))
          (should-not (lispm-kernel-pending-p runtime))
          (should-not (lispm-kernel-runtime-timer runtime))
          (should (eq (lispm-kernel-runtime-last-error runtime) 'kernel-error)))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-busy-drain-keeps-waiting ()
  (let ((runtime (lispm-kernel-create)) kinds)
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "x" (lambda (event) (push (aref event 4) kinds)))
          (cl-letf (((symbol-function 'lispm-kernel-module-drain) (lambda (&rest _) 'busy)))
            (lispm-kernel-dispatch runtime))
          (should-not kinds)
          (should (lispm-kernel-pending-p runtime))
          (should (lispm-kernel-runtime-timer runtime))
          (lispm-kernel-test--finish runtime)
          (should (equal kinds '(success))))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-scheduler-can-take-a-runtime ()
  (let* ((taken nil)
         (lispm-kernel-scheduler (lambda (runtime _) (push runtime taken) t))
         (runtime (lispm-kernel-create)))
    (unwind-protect
        (progn
          (lispm-kernel-test--submit runtime "x" #'ignore)
          (should (memq runtime taken))
          (should-not (lispm-kernel-runtime-timer runtime))
          (lispm-kernel-test--finish runtime))
      (lispm-kernel-shutdown runtime))))

(ert-deftest lispm-kernel-unload-function-closes-runtimes ()
  (let ((runtime (lispm-kernel-create)))
    (should (memq runtime lispm-kernel--runtimes))
    (lispm-kernel-unload-function)
    (should (lispm-kernel-runtime-closed runtime))
    (should-not (memq runtime lispm-kernel--runtimes))))

(defvar lispm-kernel-test--on-result nil
  "The ON-RESULT callback the faked `lispm-kernel-submit' received.")

(defun lispm-kernel-test--scan-with (events &rest keys)
  "Feed EVENTS to a session scan on a fake runtime; return (ROWS SUMMARY).
KEYS are passed to `lispm-kernel-scan-sessions'."
  (let ((runtime (lispm-kernel--runtime :handle nil :epoch 1)) result)
    (cl-letf (((symbol-function 'lispm-kernel-submit)
               (cl-function (lambda (_runtime _kind _root &key on-result &allow-other-keys)
                              (setq lispm-kernel-test--on-result on-result)
                              42)))
              ((symbol-function 'lispm-kernel-cancel) #'ignore))
      (apply #'lispm-kernel-scan-sessions runtime 'codex "/unused"
             (lambda (rows summary) (setq result (list rows summary))) keys)
      (dolist (event events) (funcall lispm-kernel-test--on-result event))
      ;; A fallback runs from a timer.
      (let ((deadline (+ (float-time) 1)))
        (while (and (null result) (< (float-time) deadline)) (sleep-for 0.001)))
      result)))

(defconst lispm-kernel-test--row
  "{\"agent\":\"codex\",\"id\":\"a\",\"cwd\":\"/p\",\"file\":\"/p/a.jsonl\",\"title\":\"t\",\"time\":1.0,\"started\":null}")

(ert-deftest lispm-kernel-session-skipped-files-do-not-fail-a-scan ()
  (pcase-let ((`(,rows ,summary)
               (lispm-kernel-test--scan-with
                (list (vector 1 42 0 0 'chunk lispm-kernel-test--row nil)
                      (vector 1 42 0 0 'success
                              "{\"rows\":1,\"errors\":0,\"skipped\":2,\"truncated\":false,\"cached\":0}" nil))
                :fallback (lambda () '((:id "fallback"))))))
    (should (equal (mapcar (lambda (row) (plist-get row :id)) rows) '("a")))
    (should (= (plist-get summary :skipped) 2))))

(ert-deftest lispm-kernel-session-fatal-errors-use-the-fallback ()
  (pcase-let ((`(,rows ,summary)
               (lispm-kernel-test--scan-with
                (list (vector 1 42 0 0 'chunk lispm-kernel-test--row nil)
                      (vector 1 42 0 0 'success "{\"rows\":1,\"errors\":1,\"skipped\":0}" nil))
                :fallback (lambda () '((:id "fallback"))))))
    (should (equal rows '((:id "fallback"))))
    (should (eq (plist-get summary :source) 'elisp))))

(ert-deftest lispm-kernel-session-malformed-summary-uses-the-fallback ()
  (pcase-let ((`(,rows ,_)
               (lispm-kernel-test--scan-with
                (list (vector 1 42 0 0 'success "not json" nil))
                :fallback (lambda () '((:id "fallback"))))))
    (should (equal rows '((:id "fallback"))))))

(ert-deftest lispm-kernel-session-timeout-uses-the-fallback ()
  (pcase-let ((`(,rows ,summary)
               (lispm-kernel-test--scan-with
                (list (vector 1 42 0 0 'timeout "" nil))
                :fallback (lambda () '((:id "fallback"))))))
    (should (equal rows '((:id "fallback"))))
    (should (eq (plist-get summary :native-error) 'timeout))))
