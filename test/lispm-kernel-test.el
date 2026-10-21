;;; lispm-kernel-test.el --- Real module integration tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(module-load (or (getenv "LISPM_KERNEL_MODULE") (error "Set LISPM_KERNEL_MODULE to the built module")))
(require 'lispm-kernel)

(defun lispm-kernel-test--submit (runtime text callback &optional generation)
  (let ((deadline (+ (float-time) 3)) request)
    (while (and (not (integerp request)) (< (float-time) deadline))
      (setq request (lispm-kernel-submit runtime 'echo text :owner 7
                                        :generation (or generation 0) :on-result callback))
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
          (lispm-kernel-test--submit runtime "Lisp 机器 λ" (lambda (event) (setq result event)))
          (lispm-kernel-test--finish runtime)
          (should (eq (aref result 4) 'success))
          (should (equal (aref result 5) "Lisp 机器 λ"))
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
                    "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"你好 kernel\"}}\n"))
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
          (should (equal (plist-get (car rows) :title) "你好 kernel"))
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
