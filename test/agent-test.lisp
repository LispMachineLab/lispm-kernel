;;;; agent-test.lisp --- Tests of CSP agent actors, effect RPC, coalescing and reconnect

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

;;;; Tiny localhost HTTP/1.1 mock server for deterministic kernel actor tests

(defstruct (mock-http-server (:constructor make-mock-http-server (socket port handler)))
  socket
  port
  handler
  (stop nil)
  thread)

(defun read-http-request (stream)
  "Read HTTP headers + Content-Length body from STREAM."
  (let ((content-length 0)
        (request-line (read-line stream nil "")))
    (loop for line = (read-line stream nil nil)
          for trimmed = (and line (string-right-trim '(#\Return) line))
          while (and trimmed (plusp (length trimmed)))
          do (when (and (>= (length trimmed) 15)
                        (string-equal "content-length:" (subseq trimmed 0 15)))
               (setf content-length
                     (parse-integer (string-trim '(#\Space #\Tab) (subseq trimmed 15))))))
    (let ((buf (make-string content-length)))
      (when (plusp content-length)
        (read-sequence buf stream))
      (values request-line buf))))

(defun send-http-response (stream status content-type body &optional chunk-delay-sec)
  "Write an HTTP/1.1 response cleanly to STREAM."
  (let ((payload (if (consp body) body (list body))))
    (format stream "HTTP/1.1 ~D OK~C~%Content-Type: ~A~C~%Connection: close~C~%~C~%"
            status #\Return content-type #\Return #\Return #\Return)
    (finish-output stream)
    (dolist (piece payload)
      (write-string piece stream)
      (finish-output stream)
      (when chunk-delay-sec
        (sleep chunk-delay-sec)))))

(defun start-mock-http-server (handler)
  "Start an HTTP/1.1 loopback server on 127.0.0.1:0 invoking HANDLER (BODY-JSON STREAM)."
  (let ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (setf (sb-bsd-sockets:sockopt-reuse-address sock) t)
    (sb-bsd-sockets:socket-bind sock #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen sock 64)
    (multiple-value-bind (_addr port) (sb-bsd-sockets:socket-name sock)
      (declare (ignore _addr))
      (let ((srv (make-mock-http-server sock port handler)))
        (setf (mock-http-server-thread srv)
              (sb-thread:make-thread
               (lambda ()
                 (loop until (mock-http-server-stop srv)
                       do (let ((client (handler-case (sb-bsd-sockets:socket-accept sock)
                                          (serious-condition () nil))))
                            (when client
                              (if (mock-http-server-stop srv)
                                  (ignore-errors (sb-bsd-sockets:socket-close client))
                                  (sb-thread:make-thread
                                   (lambda ()
                                     (let ((stream nil))
                                       (unwind-protect
                                            (progn
                                              (setf stream
                                                    (sb-bsd-sockets:socket-make-stream
                                                     client :input t :output t
                                                     :element-type 'character
                                                     :external-format :utf-8))
                                              (multiple-value-bind (_line body)
                                                  (read-http-request stream)
                                                (declare (ignore _line))
                                                (funcall handler body stream)))
                                         (when stream (ignore-errors (close stream)))
                                         (ignore-errors (sb-bsd-sockets:socket-close client)))))
                                   :name "mock-http-conn"))))))
               :name "mock-http-accept"))
        srv))))

(defun stop-mock-http-server (srv)
  "Stop mock loopback HTTP server SRV and unblock its accept loop."
  (setf (mock-http-server-stop srv) t)
  (ignore-errors
    (let ((poke (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
      (sb-bsd-sockets:socket-connect poke #(127 0 0 1) (mock-http-server-port srv))
      (sb-bsd-sockets:socket-close poke)))
  (ignore-errors (sb-bsd-sockets:socket-close (mock-http-server-socket srv)))
  (when (mock-http-server-thread srv)
    (sb-thread:join-thread (mock-http-server-thread srv) :default nil :timeout 3)))

(defun sse-event (data-json &optional event-name)
  "Format one SSE block."
  (concatenate 'string
               (if event-name (format nil "event: ~A~%" event-name) "")
               (format nil "data: ~A~%~%" data-json)))

(defun anthropic-tool-sse (id name input-json)
  "Return an Anthropic SSE response streaming one `tool_use' block."
  (concatenate
   'string
   (sse-event "{\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"usage\":{\"input_tokens\":5}}}"
              "message_start")
   (sse-event (format nil "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"~A\",\"name\":\"~A\",\"input\":{}}}"
                      id name)
              "content_block_start")
   (sse-event (format nil "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":~A}}"
                      (encode-json input-json))
              "content_block_delta")
   (sse-event "{\"type\":\"content_block_stop\",\"index\":0}" "content_block_stop")
   (sse-event "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":8}}"
              "message_delta")
   (sse-event "{\"type\":\"message_stop\"}" "message_stop")))

(defun anthropic-text-sse (text)
  "Return an Anthropic SSE response streaming one text block."
  (concatenate
   'string
   (sse-event "{\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"usage\":{\"input_tokens\":9}}}"
              "message_start")
   (sse-event "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
              "content_block_start")
   (sse-event (format nil "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":~A}}"
                      (encode-json text))
              "content_block_delta")
   (sse-event "{\"type\":\"content_block_stop\",\"index\":0}" "content_block_stop")
   (sse-event "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}"
              "message_delta")
   (sse-event "{\"type\":\"message_stop\"}" "message_stop")))

(defun turn-event-p (msg session kind)
  (and (eq (first msg) :turn-event)
       (equal (second msg) session)
       (eq (getf (third msg) :type) kind)))

;;;; Tests

(deftest agent-runs-kernel-tools-autonomously ()
  (with-directory (dir)
    (write-file (path dir "hello.txt") "kernel-needle-42")
    (let* ((step-bodies '())
           (srv (start-mock-http-server
                 (lambda (body stream)
                   (push body step-bodies)
                   (let* ((obj (parse-json body :preserve-literals t))
                          (msgs (json-get obj "messages")))
                     (if (= (length msgs) 1)
                         (send-http-response
                          stream 200 "text/event-stream"
                          (anthropic-tool-sse
                           "tu_sh" "run_shell"
                           (format nil "{\"command\":\"printf ok && ls hello.txt\",\"directory\":~A}"
                                   (encode-json dir))))
                         (if (= (length msgs) 3)
                             (send-http-response
                              stream 200 "text/event-stream"
                              (anthropic-tool-sse
                               "tu_sr" "search_files"
                               (format nil "{\"pattern\":\"kernel-needle\",\"directory\":~A}"
                                       (encode-json dir))))
                             (send-http-response
                              stream 200 "text/event-stream"
                              (anthropic-text-sse "done-autonomously")))))))))
      (unwind-protect
           (with-kernel (kernel collector)
             (let ((url (format nil "http://127.0.0.1:~D/v1/messages" (mock-http-server-port srv))))
               (send kernel
                     (message-string `(agent-start "s-auto" (:dialect :anthropic :url ,url :root ,dir :max-steps 8)))
                     (message-string `(agent-turn "s-auto" (:turn-id "t1" :body "{\"model\":\"claude-x\",\"messages\":[{\"role\":\"user\",\"content\":\"go\"}]}"))))
               (let ((msgs (await collector
                                  (lambda (ms)
                                    (some (lambda (m) (turn-event-p m "s-auto" :turn-done)) ms)))))
                 (let ((done (find-if (lambda (m) (turn-event-p m "s-auto" :turn-done)) msgs)))
                   (is done)
                   (is (string= "done-autonomously" (getf (third done) :text))))
                 (let ((snap (lispm-kernel:kernel-agent-snapshot kernel "s-auto")))
                   (is (eq :idle (getf snap :state)))
                   (is (= 2 (length (getf snap :completed-tools))))
                   (is (search "kernel-needle-42"
                               (getf (second (getf snap :completed-tools)) :result)))))))
        (stop-mock-http-server srv)))))

(deftest agent-roundtrips-editor-effects-approvals-and-timeout ()
  (with-directory (dir)
    (let* ((srv (start-mock-http-server
                 (lambda (body stream)
                   (let* ((obj (parse-json body :preserve-literals t))
                          (msgs (json-get obj "messages")))
                     (if (= (length msgs) 1)
                         (send-http-response
                          stream 200 "text/event-stream"
                          (anthropic-tool-sse "tu_ed" "edit_buffer" "{\"buffer\":\"main.el\"}"))
                         (send-http-response
                          stream 200 "text/event-stream"
                          (anthropic-text-sse "after-editor-effect"))))))))
      (unwind-protect
           (with-kernel (kernel collector)
             (let ((url (format nil "http://127.0.0.1:~D/v1/messages" (mock-http-server-port srv))))
               (send kernel
                     (message-string `(agent-start "s-eff" (:dialect :anthropic :url ,url :root ,dir
                                                            :tool-policies (:ask ("edit_buffer"))))))
               (send kernel
                     (message-string `(agent-turn "s-eff" (:turn-id "t-eff" :body "{\"messages\":[{\"role\":\"user\",\"content\":\"edit\"}]}"))))
               (let* ((msgs1 (await collector
                                    (lambda (ms)
                                      (some (lambda (m) (and (eq (first m) :approval-request)
                                                             (equal (second m) "s-eff")))
                                            ms))))
                      (req (find-if (lambda (m) (eq (first m) :approval-request)) msgs1)))
                 (is req)
                 (is (string= "tu_ed" (third req)))
                 (is (string= "edit_buffer" (fourth req)))
                 (send kernel (message-string '(agent-approval-decision "s-eff" "tu_ed" :approve))))
               (let* ((msgs2 (await collector
                                    (lambda (ms)
                                      (some (lambda (m) (and (eq (first m) :editor-effect-request)
                                                             (equal (second m) "s-eff")))
                                            ms))))
                      (eff (find-if (lambda (m) (eq (first m) :editor-effect-request)) msgs2)))
                 (is eff)
                 (is (eq :edit-buffer (fourth eff)))
                 (send kernel (message-string `(agent-effect-reply "s-eff" ,(third eff) :ok "buffer edited"))))
               (let ((msgs3 (await collector
                                   (lambda (ms)
                                     (some (lambda (m) (turn-event-p m "s-eff" :turn-done)) ms)))))
                 (let ((done (find-if (lambda (m) (turn-event-p m "s-eff" :turn-done)) msgs3)))
                   (is done)
                   (is (string= "after-editor-effect" (getf (third done) :text)))))))
        (stop-mock-http-server srv))))
  ;; Now verify effect timeout settles cleanly when Emacs never answers
  (let* ((srv (start-mock-http-server
               (lambda (body stream)
                 (let* ((obj (parse-json body :preserve-literals t))
                        (msgs (json-get obj "messages")))
                   (if (= (length msgs) 1)
                       (send-http-response
                        stream 200 "text/event-stream"
                        (anthropic-tool-sse "tu_slow" "eval_elisp" "{\"code\":\"(+ 1 2)\"}"))
                       (send-http-response
                        stream 200 "text/event-stream"
                        (anthropic-text-sse "recovered-from-timeout"))))))))
    (unwind-protect
         (with-globals ((lispm-kernel:*agent-effect-timeout* 0.15d0))
           (with-kernel (kernel collector)
             (let ((url (format nil "http://127.0.0.1:~D/v1/messages" (mock-http-server-port srv))))
               (send kernel
                     (message-string `(agent-start "s-to" (:dialect :anthropic :url ,url)))
                     (message-string `(agent-turn "s-to" (:turn-id "t-to" :body "{\"messages\":[{\"role\":\"user\",\"content\":\"eval\"}]}"))))
               (let ((msgs (await collector
                                  (lambda (ms)
                                    (some (lambda (m) (turn-event-p m "s-to" :turn-done)) ms)))))
                 (is (some (lambda (m) (turn-event-p m "s-to" :effect-timeout)) msgs))
                 (is (some (lambda (m)
                             (and (turn-event-p m "s-to" :turn-done)
                                  (string= "recovered-from-timeout" (getf (third m) :text))))
                           msgs))))))
      (stop-mock-http-server srv))))

(deftest agent-cancel-and-viewport-coalescing ()
  ;; Cancel mid-sleep shell tool
  (with-directory (dir)
    (let* ((srv (start-mock-http-server
                 (lambda (_body stream)
                   (declare (ignore _body))
                   (send-http-response
                    stream 200 "text/event-stream"
                    (anthropic-tool-sse "tu_sleep" "run_shell" "{\"command\":\"sleep 10\"}"))))))
      (unwind-protect
           (with-kernel (kernel collector)
             (let ((url (format nil "http://127.0.0.1:~D/v1/messages" (mock-http-server-port srv))))
               (send kernel
                     (message-string `(agent-start "s-can" (:dialect :anthropic :url ,url :root ,dir)))
                     (message-string `(agent-turn "s-can" (:turn-id "t-can" :body "{\"messages\":[{\"role\":\"user\",\"content\":\"sleep\"}]}"))))
               ;; Wait until HTTP stream finishes step 1 and enters acting
               (await collector (lambda (ms) (some (lambda (m) (turn-event-p m "s-can" :step-response)) ms)))
               (send kernel "(agent-cancel \"s-can\")")
               (let ((msgs (await collector (lambda (ms) (some (lambda (m) (turn-event-p m "s-can" :turn-cancelled)) ms)))))
                 (is (some (lambda (m) (turn-event-p m "s-can" :turn-cancelled)) msgs))
                 (is (eq :idle (getf (lispm-kernel:kernel-agent-snapshot kernel "s-can") :state))))))
        (stop-mock-http-server srv))))
  ;; Hidden viewport coalesces small slow chunks into a single batch on resync/flush
  (let* ((chunks
           (list (sse-event "{\"type\":\"message_start\",\"message\":{\"id\":\"mv\"}}" "message_start")
                 (sse-event "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}" "content_block_start")
                 (sse-event "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"A\"}}" "content_block_delta")
                 (sse-event "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"B\"}}" "content_block_delta")
                 (sse-event "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"C\"}}" "content_block_delta")
                 (concatenate 'string
                              (sse-event "{\"type\":\"content_block_stop\",\"index\":0}" "content_block_stop")
                              (sse-event "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}" "message_delta")
                              (sse-event "{\"type\":\"message_stop\"}" "message_stop"))))
         (srv (start-mock-http-server
               (lambda (_body stream)
                 (declare (ignore _body))
                 (send-http-response stream 200 "text/event-stream" chunks 0.015)))))
    (unwind-protect
         (with-globals ((lispm-kernel:*agent-hidden-flush-ms* 500))
           (with-kernel (kernel collector)
             (let ((url (format nil "http://127.0.0.1:~D/v1/messages" (mock-http-server-port srv))))
               (send kernel
                     (message-string `(agent-start "s-hid" (:dialect :anthropic :url ,url :viewport :hidden)))
                     (message-string `(agent-turn "s-hid" (:body "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"))))
               (let* ((msgs (await collector (lambda (ms) (some (lambda (m) (turn-event-p m "s-hid" :turn-done)) ms))))
                      (deltas (loop for m in msgs
                                    when (turn-event-p m "s-hid" :delta)
                                      collect (getf (third m) :text))))
                 (is (string= "ABC" (apply #'concatenate 'string deltas)))
                 ;; Coalesced well under 3 separate delta wire messages
                 (is (<= (length deltas) 2))))))
      (stop-mock-http-server srv))))

(deftest agent-24-concurrent-actors-stress ()
  (with-directory (dir)
    (let* ((srv (start-mock-http-server
                 (lambda (body stream)
                   (let* ((obj (parse-json body :preserve-literals t))
                          (msgs (json-get obj "messages")))
                     (if (= (length msgs) 1)
                         (send-http-response
                          stream 200 "text/event-stream"
                          (anthropic-tool-sse "tu_1" "run_shell"
                                              (format nil "{\"command\":\"echo worker-ok\",\"directory\":~A}"
                                                      (encode-json dir))))
                         (send-http-response
                          stream 200 "text/event-stream"
                          (anthropic-text-sse "concurrent-ok"))))))))
      (unwind-protect
           (with-kernel (kernel collector :io-workers 4 :reactor-slots 64)
             (let ((url (format nil "http://127.0.0.1:~D/v1/messages" (mock-http-server-port srv)))
                   (sessions (loop for i from 1 to 24 collect (format nil "agent-~2,'0D" i))))
               (dolist (s sessions)
                 (send kernel
                       (message-string `(agent-start ,s (:dialect :anthropic :url ,url :root ,dir)))
                       (message-string `(agent-turn ,s (:turn-id "t" :body "{\"messages\":[{\"role\":\"user\",\"content\":\"run\"}]}")))))
               (let ((msgs (await collector
                                  (lambda (ms)
                                    (every (lambda (s)
                                             (some (lambda (m) (turn-event-p m s :turn-done)) ms))
                                           sessions))
                                  :timeout 25)))
                 (dolist (s sessions)
                   (is (some (lambda (m) (turn-event-p m s :turn-done)) msgs)))
                 (is (= 24 (length (lispm-kernel:kernel-agent-list kernel)))))))
        (stop-mock-http-server srv)))))

(deftest agent-socket-server-reconnect-preserves-actors ()
  (let* ((sock-path (format nil "/tmp/lk-test-~D-~D.sock"
                            (sb-posix:getpid) (random 100000)))
         (ready-gate (sb-concurrency:make-gate :name "sock-ready" :open nil))
           (srv (start-mock-http-server
                 (lambda (_body stream)
                   (declare (ignore _body))
                   ;; Delayed response so client 1 detaches BEFORE turn finishes!
                   (send-http-response stream 200 "text/event-stream"
                                       (list
                                        (sse-event "{\"type\":\"message_start\",\"message\":{\"id\":\"mr\"}}" "message_start")
                                        (sse-event "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}" "content_block_start")
                                        (sse-event "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"while-detached\"}}" "content_block_delta")
                                        (concatenate
                                         'string
                                         (sse-event "{\"type\":\"content_block_stop\",\"index\":0}" "content_block_stop")
                                         (sse-event "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}" "message_delta")
                                         (sse-event "{\"type\":\"message_stop\"}" "message_stop")))
                                       0.08))))
           (server-thread
             (sb-thread:make-thread
              (lambda ()
                (lispm-kernel:run-socket-server
                 sock-path
                 :on-ready (lambda (_p)
                             (declare (ignore _p))
                             (sb-concurrency:open-gate ready-gate))))
              :name "test-sock-server")))
      (unwind-protect
           (progn
             (is (sb-concurrency:wait-on-gate ready-gate :timeout 5))
             (let ((url (format nil "http://127.0.0.1:~D/v1/messages" (mock-http-server-port srv))))
               ;; Client 1 starts an agent turn, receives hello + session-ready, then detaches
               (let ((c1 (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
                 (sb-bsd-sockets:socket-connect c1 sock-path)
                 (let ((s1 (sb-bsd-sockets:socket-make-stream
                            c1 :input t :output t :buffering :full :external-format :utf-8)))
                   (is (eq :hello (first (read-message (read-line s1)))))
                   (write-line (message-string `(agent-start "s-re" (:dialect :anthropic :url ,url))) s1)
                   (write-line (message-string `(agent-turn "s-re" (:turn-id "tr1" :body "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"))) s1)
                   (finish-output s1)
                   ;; Wait for turn-started before closing client 1 without (quit)
                   (let ((started (read-message (read-line s1))))
                     (declare (ignore started)))
                   (ignore-errors (close s1))
                   (ignore-errors (sb-bsd-sockets:socket-close c1))))
               ;; Wait for the background HTTP turn inside P_agents to complete while detached
               (sleep 0.5)
               ;; Client 2 reconnects and calls (agent-resync "s-re" :since-seq 0)
               (let ((c2 (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
                 (sb-bsd-sockets:socket-connect c2 sock-path)
                 (let ((s2 (sb-bsd-sockets:socket-make-stream
                            c2 :input t :output t :buffering :full :external-format :utf-8))
                       (snap nil))
                   (is (eq :hello (first (read-message (read-line s2)))))
                   (write-line (message-string '(agent-resync "s-re" :since-seq 0)) s2)
                   (finish-output s2)
                   (loop repeat 16
                         for line = (read-line s2 nil nil)
                         for msg = (and line (read-message line))
                         while msg
                         when (and (eq (first msg) :agent-snapshot)
                                   (equal (second msg) "s-re"))
                           do (setf snap (third msg))
                              (return))
                   (is snap)
                   (is (eq :idle (getf snap :state)))
                   (is (string= "while-detached" (getf (getf snap :stream) :text)))
                   (is (= 1 (length (getf snap :completed-turns))))
                   (write-line "(quit)" s2)
                   (finish-output s2)
                   (ignore-errors (close s2))
                   (ignore-errors (sb-bsd-sockets:socket-close c2))))))
        (stop-mock-http-server srv)
        (sb-thread:join-thread server-thread :default nil :timeout 5)
        (ignore-errors (sb-posix:unlink sock-path)))))
