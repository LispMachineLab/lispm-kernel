;;;; runtime-test.lisp --- Tests of requests, workers and the outbox

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

;;; A kernel whose messages are read back with the wire's reader, so
;;; (done 1 success 5) is (:done 1 :success 5) here.

(defstruct (collector (:constructor make-collector ()))
  (lock (sb-thread:make-mutex :name "collector"))
  (messages '())
  ;; While true, the sink waits: Emacs not reading.
  (stalled nil))

(defun collector-sink (collector)
  (lambda (batch)
    (loop while (collector-stalled collector) do (sleep 0.002))
    (sb-thread:with-mutex ((collector-lock collector))
      (setf (collector-messages collector)
            (append (collector-messages collector) (mapcar #'read-message batch))))))

(defun messages (collector)
  (sb-thread:with-mutex ((collector-lock collector))
    (copy-list (collector-messages collector))))

(defun await (collector predicate &key (timeout 10))
  "Wait until PREDICATE is true of COLLECTOR's messages; return them."
  (let ((deadline (+ (get-internal-real-time) (* timeout internal-time-units-per-second))))
    (loop
      (let ((messages (messages collector)))
        (when (funcall predicate messages)
          (return messages))
        (when (> (get-internal-real-time) deadline)
          (return messages))
        (sleep 0.002)))))

(defun done-of (id messages)
  (find-if (lambda (message) (and (eq (first message) :done) (eql (second message) id))) messages))

(defun answered (collector &rest ids)
  "Wait until every request of IDS is answered; return the messages."
  (await collector (lambda (messages) (every (lambda (id) (done-of id messages)) ids))))

(defmacro with-kernel ((kernel collector &rest options) &body body)
  `(let* ((,collector (make-collector))
          (,kernel (lispm-kernel:start-kernel (collector-sink ,collector) ,@options)))
     (unwind-protect (progn ,@body)
       (setf (collector-stalled ,collector) nil)
       (lispm-kernel:stop-kernel ,kernel :timeout 5))))

(defun send (kernel &rest messages)
  (dolist (message messages)
    (lispm-kernel:handle-line kernel message)))

(deftest runtime-answers-each-request-once ()
  (with-kernel (kernel collector)
    (send kernel
          "(submit 1 echo (\"x\" :k [1 2]))"
          "(submit 2 wait (:chunks 3))"
          "(submit 3 nope nil)"
          "(submit 4 wait (:fail \"boom\"))")
    (let ((messages (answered collector 1 2 3 4)))
      (is (equalp '(:done 1 :success ("x" :k #(1 2))) (done-of 1 messages)))
      (is (equal '(:done 2 :success 0) (done-of 2 messages)))
      (is (equal '(:done 3 :rejected :unknown-job) (done-of 3 messages)))
      (is (equal '(:done 4 :failed "boom") (done-of 4 messages)))
      ;; Chunks come in order, before their done.
      (is (equal '((:chunk 2 0) (:chunk 2 1) (:chunk 2 2) (:done 2 :success 0))
                 (remove-if-not (lambda (message) (eql (second message) 2)) messages)))
      (is (= 4 (count :done messages :key #'first))))))

(deftest runtime-rejects-duplicates-and-capacity ()
  (with-globals ((lispm-kernel::*max-requests* 3)
                 (lispm-kernel::*max-requests-per-owner* 2))
    (with-kernel (kernel collector :io-workers 1)
      (send kernel
            "(submit 1 wait (:milliseconds 3000) :owner 1)"
            "(submit 1 echo 1)"
            "(submit 2 wait (:milliseconds 3000) :owner 1)"
            "(submit 3 wait (:milliseconds 3000) :owner 1)"
            "(submit 4 wait (:milliseconds 3000) :owner 2)"
            "(submit 5 wait (:milliseconds 3000) :owner 3)")
      (let ((messages (await collector (lambda (messages) (= 3 (count :done messages :key #'first))))))
        (is (equal '(:done 1 :rejected :duplicate)
                   (find-if (lambda (m) (and (eq (first m) :done) (eq (fourth m) :duplicate))) messages)))
        (is (equal '(:done 3 :rejected :capacity) (done-of 3 messages)))
        (is (equal '(:done 5 :rejected :capacity) (done-of 5 messages))))
      (send kernel "(cancel 1)" "(cancel 2)" "(cancel 4)")
      (let ((messages (answered collector 2 4)))
        (is (equal '(:done 2 :cancelled nil) (done-of 2 messages)))
        (is (equal '(:done 4 :cancelled nil) (done-of 4 messages)))))))

(deftest runtime-generations ()
  (with-kernel (kernel collector :io-workers 1)
    (send kernel
          "(submit 1 wait (:milliseconds 5000) :owner 7 :generation 1)"
          "(submit 2 wait (:milliseconds 5000) :owner 7 :generation 1)"
          "(submit 3 wait (:milliseconds 5000) :owner 8 :generation 1)")
    (sleep 0.05)
    ;; A newer generation cancels the running and the queued of its owner only.
    (send kernel "(submit 4 echo four :owner 7 :generation 2)")
    (let ((messages (answered collector 1 2)))
      (is (equal '(:done 1 :cancelled nil) (done-of 1 messages)))
      (is (equal '(:done 2 :cancelled nil) (done-of 2 messages)))
      (is (eq nil (done-of 3 messages))))
    (send kernel "(submit 5 echo old :owner 7 :generation 1)" "(supersede 8 3)")
    (let ((messages (answered collector 3 4 5)))
      (is (equal '(:done 5 :rejected :stale) (done-of 5 messages)))
      (is (equal '(:done 3 :cancelled nil) (done-of 3 messages)))
      (is (equal '(:done 4 :success :four) (done-of 4 messages))))))

(deftest runtime-cancels-queued-at-once ()
  (with-kernel (kernel collector :io-workers 1)
    (send kernel
          "(submit 1 wait (:milliseconds 5000))"
          "(submit 2 wait (:milliseconds 5000))"
          "(cancel 2)"
          "(cancel 99)")
    (let ((messages (answered collector 2)))
      (is (equal '(:done 2 :cancelled nil) (done-of 2 messages)))
      (is (eq nil (done-of 1 messages))))
    (send kernel "(cancel 1)")
    (is (equal '(:done 1 :cancelled nil) (done-of 1 (answered collector 1))))))

(deftest runtime-priority-and-aging ()
  (with-kernel (kernel collector :io-workers 1)
    (send kernel "(submit 1 wait (:milliseconds 5000))")
    ;; The one worker busy with 1, the rest wait in the queue.
    (sleep 0.05)
    (send kernel
          "(submit 2 wait nil :priority 0)"
          "(submit 3 wait nil :priority -5)"
          "(submit 4 wait nil :priority 5)")
    (sleep 0.05)
    (send kernel "(cancel 1)")
    (let ((order (mapcar #'second
                         (remove :done (answered collector 1 2 3 4) :key #'first :test-not #'eq))))
      (is (equal '(1 4 2 3) order))))
  (let ((request (lispm-kernel::make-request 1 (gethash :echo lispm-kernel::*jobs*) nil 0 0 2)))
    (is (= 2 (lispm-kernel::effective-priority request (lispm-kernel::request-submitted request))))
    (is (= 4 (lispm-kernel::effective-priority
              request (+ (lispm-kernel::request-submitted request)
                         (floor internal-time-units-per-second 10)))))))

(deftest runtime-backpressure ()
  (with-globals ((lispm-kernel::*outbox-limit* 200))
    (with-kernel (kernel collector)
      (setf (collector-stalled collector) t)
      (send kernel "(submit 1 wait (:chunks 100000))")
      (sleep 0.1)
      ;; Emacs reading nothing, the job waits with little queued.
      (let ((outbox (lispm-kernel::kernel-outbox kernel)))
        (is (<= (lispm-kernel::outbox-waiting outbox) 200)))
      (send kernel "(cancel 1)")
      (setf (collector-stalled collector) nil)
      (let ((messages (answered collector 1)))
        (is (equal '(:done 1 :cancelled nil) (done-of 1 messages)))
        (is (< (count :chunk messages :key #'first) 1000))))))

(lispm-kernel:define-job (float-result) (input)
  1.5)

(deftest runtime-results-emacs-cannot-have ()
  (with-globals ((lispm-kernel::*max-final-length* 100))
    (with-kernel (kernel collector)
      (send kernel
            "(submit 1 float-result nil)"
            (format nil "(submit 2 echo ~S)" (make-string 200 :initial-element #\a)))
      (let ((messages (answered collector 1 2)))
        (is (eq :failed (third (done-of 1 messages))))
        (is (search "cannot be sent" (fourth (done-of 1 messages))))
        (is (equal '(:done 2 :failed "The result is too long to send to Emacs") (done-of 2 messages)))))))

(deftest runtime-protocol ()
  (with-kernel (kernel collector)
    (send kernel "(ping 1 \"two\")" "(bogus" "(submit -1 echo nil)" "(frobnicate)" "(stats)")
    (let ((messages (await collector (lambda (messages) (find :stats messages :key #'first)))))
      (is (equal '(:pong 1 "two") (first messages)))
      (is (= 3 (count :protocol-error messages :key #'first)))
      (is (= 0 (getf (second (find :stats messages :key #'first)) :requests))))
    (is (eq :quit (lispm-kernel:handle-line kernel "(quit)")))))

(deftest runtime-malformed-submissions-are-answered ()
  (with-kernel (kernel collector)
    (send kernel
          "(submit 1 wait (:milliseconds 3000))"
          "(submit 2 echo 1.5)"
          "(submit 3 echo (a . b))"
          "(submit 1 echo 'a)"
          "(submit x echo 1)")
    (let ((messages (await collector (lambda (messages)
                                       (and (done-of 3 messages)
                                            (= 4 (count :protocol-error messages :key #'first)))))))
      (is (equal '(:done 2 :rejected :malformed) (done-of 2 messages)))
      (is (equal '(:done 3 :rejected :malformed) (done-of 3 messages)))
      (is (= 4 (count :protocol-error messages :key #'first)))
      ;; Request 1 was accepted: a malformed line with its id leaves it be.
      (is (eq nil (done-of 1 messages))))
    (send kernel "(cancel 1)")
    (let ((messages (answered collector 1)))
      (is (equal '(:done 1 :cancelled nil) (done-of 1 messages)))
      (is (= 1 (count 1 (remove :done messages :key #'first :test-not #'eq) :key #'second)))))
  (is (eql 12 (lispm-kernel::submit-id "(submit 12 echo 1.5)")))
  (is (eq nil (lispm-kernel::submit-id "(submit 12x echo)")))
  (is (eq nil (lispm-kernel::submit-id "(cancel 12)"))))

(deftest runtime-closed-kernel-rejects ()
  (let* ((collector (make-collector))
         (kernel (lispm-kernel:start-kernel (collector-sink collector))))
    (lispm-kernel:handle-line kernel "(submit 1 wait (:milliseconds 5000))")
    (sleep 0.02)
    (lispm-kernel:stop-kernel kernel :timeout 5)
    (lispm-kernel:handle-line kernel "(submit 2 echo 2)")
    (let ((messages (messages collector)))
      (is (equal '(:done 1 :cancelled nil) (done-of 1 messages))))))

(deftest runtime-many-requests-cancelled-at-random ()
  (with-kernel (kernel collector :io-workers 3)
    (let ((random (sb-ext:seed-random-state 42)))
      (loop for id from 1 to 120
            do (send kernel (format nil "(submit ~D wait (:chunks ~D :milliseconds ~D) :owner ~D)"
                                    id (random 4 random) (random 20 random) (mod id 3)))
               (when (zerop (random 3 random))
                 (send kernel (format nil "(cancel ~D)" (1+ (random id random))))))
      (let ((messages (apply #'answered collector (loop for id from 1 to 120 collect id))))
        (loop for id from 1 to 120
              for own = (remove id messages :key #'second :test-not #'eql)
              do (is (= 1 (count :done own :key #'first)))
                 (is (eq :done (first (car (last own))))))))))

(deftest runtime-parallel-map ()
  (is (equal '(1 4 9 16 25) (lispm-kernel:parallel-map (lambda (n) (* n n)) '(1 2 3 4 5) :threads 3)))
  (is (equal '() (lispm-kernel:parallel-map #'identity '())))
  (signals error (lispm-kernel:parallel-map (lambda (n) (if (= n 3) (error "three") n)) '(1 2 3 4)))
  ;; Within a cancelled request every thread stops.
  (let* ((request (lispm-kernel::make-request 1 (gethash :echo lispm-kernel::*jobs*) nil 0 0 0))
         (lispm-kernel::*request* request)
         (seen 0)
         (lock (sb-thread:make-mutex)))
    (setf (lispm-kernel::request-cancelled request) t)
    (is (eq nil (catch 'lispm-kernel::cancelled
                       (lispm-kernel:parallel-map (lambda (n)
                                                    (sb-thread:with-mutex (lock) (incf seen))
                                                    (lispm-kernel:checkpoint)
                                                    n)
                                                  (loop for n below 100 collect n))
                       :finished)))
    (is (<= seen 4))))
