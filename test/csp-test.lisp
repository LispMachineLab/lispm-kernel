;;;; csp-test.lisp --- Tests of lock-free CSP channels, cancel gates and work groups

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

(deftest csp-mbox-fifo-and-drain ()
  (let ((mb (lispm-kernel/csp:make-mbox :name "test-mbox")))
    (is (lispm-kernel/csp:mbox-empty-p mb))
    (lispm-kernel/csp:mbox-send mb :one)
    (lispm-kernel/csp:mbox-send mb :two)
    (lispm-kernel/csp:mbox-send mb :three)
    (is (= 3 (lispm-kernel/csp:mbox-count mb)))
    (is (eq :one (lispm-kernel/csp:mbox-recv mb :timeout 1)))
    (is (equal '(:two :three) (lispm-kernel/csp:mbox-drain mb)))
    (is (lispm-kernel/csp:mbox-empty-p mb))))

(deftest csp-cancel-token-hooks-and-immediate-wake ()
  (let ((token (lispm-kernel/csp:make-cancel-token :name "test-cancel"))
        (fired '()))
    (is (not (lispm-kernel/csp:cancelled-p token)))
    (is (not (lispm-kernel/csp:await-cancel token :timeout 0.005)))
    (is (lispm-kernel/csp:register-cancel-hook token (lambda () (push :a fired))))
    (is (lispm-kernel/csp:register-cancel-hook token (lambda () (push :b fired))))
    (is (lispm-kernel/csp:cancel! token))
    ;; Idempotent second cancel does not re-fire hooks.
    (is (not (lispm-kernel/csp:cancel! token)))
    (is (lispm-kernel/csp:cancelled-p token))
    (is (lispm-kernel/csp:await-cancel token :timeout 0))
    (is (equal '(:b :a) fired))
    ;; Registering on an already-cancelled token fires immediately.
    (is (not (lispm-kernel/csp:register-cancel-hook token (lambda () (push :late fired)))))
    (is (equal '(:late :b :a) fired))))

(deftest csp-credit-sink-targeted-cancel-under-backpressure ()
  (let ((sink (lispm-kernel/csp:make-credit-sink :limit 10))
        (tok-cancelled (lispm-kernel/csp:make-cancel-token :name "c1"))
        (tok-live (lispm-kernel/csp:make-cancel-token :name "c2"))
        (outcomes (lispm-kernel/csp:make-mbox :name "outcomes")))
    ;; First chunk fills the 10-byte budget.
    (is (lispm-kernel/csp:credit-sink-put-chunk sink "0123456789" :token tok-live :limit 10))
    (is (= 10 (lispm-kernel/csp:credit-sink-waiting sink)))
    ;; Two senders now block on credit; cancelling only tok-cancelled wakes it immediately
    ;; while tok-live remains waiting until credit is drained.
    (let ((t1 (sb-thread:make-thread
               (lambda ()
                 (lispm-kernel/csp:mbox-send
                  outcomes
                  (cons :t1 (lispm-kernel/csp:credit-sink-put-chunk
                             sink "blocked-1" :token tok-cancelled :limit 10))))))
          (t2 (sb-thread:make-thread
               (lambda ()
                 (lispm-kernel/csp:mbox-send
                  outcomes
                  (cons :t2 (lispm-kernel/csp:credit-sink-put-chunk
                             sink "blocked-2" :token tok-live :limit 10)))))))
      (sleep 0.02)
      (lispm-kernel/csp:cancel! tok-cancelled)
      (is (equal '(:t1 . nil) (lispm-kernel/csp:mbox-recv outcomes :timeout 1)))
      ;; Control messages bypass backpressure even while t2 waits.
      (is (lispm-kernel/csp:credit-sink-put-control sink "(done 1 cancelled nil)"))
      (is (equal '("0123456789" "(done 1 cancelled nil)")
                 (lispm-kernel/csp:credit-sink-take sink)))
      ;; Draining freed room for t2.
      (is (equal '(:t2 . t) (lispm-kernel/csp:mbox-recv outcomes :timeout 1)))
      (is (equal '("blocked-2") (lispm-kernel/csp:credit-sink-take sink)))
      (lispm-kernel/csp:credit-sink-close sink)
      (is (null (lispm-kernel/csp:credit-sink-take sink)))
      (sb-thread:join-thread t1 :default nil :timeout 2)
      (sb-thread:join-thread t2 :default nil :timeout 2))))

(deftest csp-work-group-makes-progress-even-when-subworkers-busy ()
  (let ((wg (lispm-kernel/csp:make-work-group :workers 2 :name "test-wg"))
        (blocker (sb-concurrency:make-gate :name "blocker" :open nil)))
    (unwind-protect
         (let ((holder (sb-thread:make-thread
                        (lambda ()
                          (lispm-kernel/csp:work-group-map
                           wg (lambda (x)
                                (sb-concurrency:wait-on-gate blocker :timeout 5)
                                x)
                           '(1 2 3) :threads 3)))))
           (sleep 0.03)
           ;; Both subworkers are occupied on `blocker', yet caller work-helping
           ;; completes a fresh batch immediately without deadlock.
           (let ((started (get-internal-real-time)))
             (is (equal '(10 20 30 40)
                        (lispm-kernel/csp:work-group-map wg (lambda (x) (* x 10))
                                                         '(1 2 3 4) :threads 4)))
             (is (< (- (get-internal-real-time) started) internal-time-units-per-second)))
           (sb-concurrency:open-gate blocker)
           (is (equal '(1 2 3) (sb-thread:join-thread holder :default nil :timeout 2))))
      (sb-concurrency:open-gate blocker)
      (lispm-kernel/csp:stop-work-group wg :timeout 2))))

(deftest csp-cancel-hook-always-observes-cancelled-p ()
  (dotimes (_ 200)
    (let ((token (lispm-kernel/csp:make-cancel-token :name "race-cancel"))
          (saw-unopen nil))
      (let ((canceller (sb-thread:make-thread (lambda () (lispm-kernel/csp:cancel! token))))
            (watcher (sb-thread:make-thread
                      (lambda ()
                        (lispm-kernel/csp:register-cancel-hook
                         token
                         (lambda ()
                           (unless (lispm-kernel/csp:cancelled-p token)
                             (setf saw-unopen t))))))))
        (sb-thread:join-thread canceller :default nil :timeout 2)
        (sb-thread:join-thread watcher :default nil :timeout 2)
        (is (not saw-unopen))
        (is (lispm-kernel/csp:cancelled-p token))))))

(deftest csp-credit-sink-single-hook-and-closed-control ()
  (let ((sink (lispm-kernel/csp:make-credit-sink :limit 4))
        (token (lispm-kernel/csp:make-cancel-token :name "backpressure-hooks")))
    (is (lispm-kernel/csp:credit-sink-put-chunk sink "0123" :token token :limit 4))
    (let ((sender (sb-thread:make-thread
                   (lambda ()
                     (lispm-kernel/csp:credit-sink-put-chunk sink "blocked" :token token :limit 4)))))
      ;; Span multiple 50ms wait iterations to verify hooks do not accumulate.
      (sleep 0.16)
      (is (<= (length (lispm-kernel/csp::cancel-token-hooks token)) 1))
      (lispm-kernel/csp:cancel! token)
      (is (null (sb-thread:join-thread sender :default :hung :timeout 2))))
    (lispm-kernel/csp:credit-sink-close sink)
    (is (equal '("0123") (lispm-kernel/csp:credit-sink-take sink)))
    (is (not (lispm-kernel/csp:credit-sink-put-control sink "(pong)")))))

(deftest csp-work-group-fast-path-respects-context-and-token ()
  (let ((token (lispm-kernel/csp:make-cancel-token :name "fast-path"))
        (wrapped 0))
    (is (equal '(2)
               (lispm-kernel/csp:work-group-map
                nil #'1+ '(1) :threads 1 :token token
                :context (lambda (thunk) (incf wrapped) (funcall thunk)))))
    (is (= 1 wrapped))
    (lispm-kernel/csp:cancel! token)
    (is (equal '(nil nil)
               (lispm-kernel/csp:work-group-map
                nil (lambda (_) (declare (ignore _)) (error "must not run"))
                '(1 2) :threads 1 :token token)))))

(deftest csp-credit-sink-try-put-and-stream-credit-isolation ()
  (let* ((sink (lispm-kernel/csp:make-credit-sink :limit 30))
         (sc1 (lispm-kernel/csp:make-stream-credit :limit 10))
         (sc2 (lispm-kernel/csp:make-stream-credit :limit 10))
         (sc3 (lispm-kernel/csp:make-stream-credit :limit 100))
         (cancel-tok (lispm-kernel/csp:make-cancel-token :name "try-cancel"))
         (woken (lispm-kernel/csp:make-mbox :name "room-hook")))
    (lispm-kernel/csp:credit-sink-register-room-hook
     sink (lambda () (lispm-kernel/csp:mbox-send woken :woke)))
    ;; Stream 1 fills its 10-byte limit; extra chunks return :full immediately.
    (is (eq :sent (lispm-kernel/csp:credit-sink-try-put-chunk sink "12345" :stream-credit sc1)))
    (is (eq :sent (lispm-kernel/csp:credit-sink-try-put-chunk sink "67890" :stream-credit sc1)))
    (is (= 10 (lispm-kernel/csp:stream-credit-waiting sc1)))
    (is (eq :full (lispm-kernel/csp:credit-sink-try-put-chunk sink "x" :stream-credit sc1)))
    (is (= 10 (lispm-kernel/csp:stream-credit-waiting sc1)))
    ;; Sibling stream 2 remains unblocked while stream 1 is saturated.
    (is (eq :sent (lispm-kernel/csp:credit-sink-try-put-chunk sink "alpha" :stream-credit sc2)))
    (is (= 5 (lispm-kernel/csp:stream-credit-waiting sc2)))
    ;; Global limit exhaustion rolls back per-stream credit cleanly.
    (is (eq :sent (lispm-kernel/csp:credit-sink-try-put-chunk sink "0123456789abcde" :stream-credit sc3)))
    (is (= 30 (lispm-kernel/csp:credit-sink-waiting sink)))
    (is (eq :full (lispm-kernel/csp:credit-sink-try-put-chunk sink "z" :stream-credit sc3)))
    (is (= 15 (lispm-kernel/csp:stream-credit-waiting sc3)))
    ;; Cancelled token rejects without consuming credit.
    (lispm-kernel/csp:cancel! cancel-tok)
    (is (eq :cancelled (lispm-kernel/csp:credit-sink-try-put-chunk sink "skip" :token cancel-tok :stream-credit sc3)))
    (is (= 15 (lispm-kernel/csp:stream-credit-waiting sc3)))
    ;; Taking messages frees both global and per-stream credits and fires room hooks.
    (is (equal '("12345" "67890" "alpha" "0123456789abcde")
               (lispm-kernel/csp:credit-sink-take sink)))
    (is (= 0 (lispm-kernel/csp:credit-sink-waiting sink)))
    (is (= 0 (lispm-kernel/csp:stream-credit-waiting sc1)))
    (is (= 0 (lispm-kernel/csp:stream-credit-waiting sc2)))
    (is (= 0 (lispm-kernel/csp:stream-credit-waiting sc3)))
    (is (eq :woke (lispm-kernel/csp:mbox-recv woken :timeout 1)))
    ;; Closed sink rejects without queueing.
    (lispm-kernel/csp:credit-sink-close sink)
    (is (eq :closed (lispm-kernel/csp:credit-sink-try-put-chunk sink "after" :stream-credit sc1)))
    (is (null (lispm-kernel/csp:credit-sink-take sink)))))

