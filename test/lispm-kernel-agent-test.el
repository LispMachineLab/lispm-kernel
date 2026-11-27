;;; lispm-kernel-agent-test.el --- Emacs integration for kernel SSE, actors, socket -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

;;; Commentary:

;; Integration tests running against the compiled `lispm-kernel' binary
;; for `llm-stream', CSP agent actors, editor effect RPC, and socket
;; detach/reconnect.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'lispm-kernel-test)
(require 'lispm-kernel-exec)

(defun lispm-kernel-agent-test--start-sse-server (handler)
  "Start a localhost IPv4 HTTP SSE server calling HANDLER (BODY PROC)."
  (let ((server
         (make-network-process
          :name "lispm-kernel-agent-sse"
          :server t :host 'local :service t
          :family 'ipv4 :coding 'utf-8-unix :noquery t
          :filter (lambda (proc text)
                    (let* ((acc (concat (or (process-get proc 'acc) "") text))
                           (sep (string-search "\r\n\r\n" acc)))
                      (process-put proc 'acc acc)
                      (when sep
                        (let ((headers (substring acc 0 sep))
                              (body (substring acc (+ sep 4)))
                              (clen 0))
                          (when (string-match "Content-Length:[ \t]*\\([0-9]+\\)" headers)
                            (setq clen (string-to-number (match-string 1 headers))))
                          (when (>= (string-bytes body) clen)
                            (funcall handler body proc)))))))))
    (cons server (format "http://127.0.0.1:%d" (process-contact server :service)))))

(defun lispm-kernel-agent-test--stop-server (pair)
  "Stop mock SSE server PAIR."
  (when (and pair (process-live-p (car pair)))
    (delete-process (car pair)))
  (dolist (p (process-list))
    (when (string-prefix-p "lispm-kernel-agent-sse" (process-name p))
      (ignore-errors (delete-process p)))))

(defun lispm-kernel-agent-test--send-sse (proc body-text)
  "Send HTTP/1.1 SSE BODY-TEXT on PROC and close."
  (process-send-string
   proc
   (concat "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
           body-text))
  (process-send-eof proc))

(ert-deftest lispm-kernel-agent-llm-stream-anthropic ()
  "Verify `lispm-kernel-llm-stream' decodes Anthropic SSE off Emacs's thread."
  (let* ((sse (concat
               "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"usage\":{\"input_tokens\":6}}}\n\n"
               "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
               "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello \"}}\n\n"
               "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"kernel\"}}\n\n"
               "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":3}}\n\n"
               "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"))
         (srv (lispm-kernel-agent-test--start-sse-server
               (lambda (_body proc) (lispm-kernel-agent-test--send-sse proc sse))))
         (deltas nil)
         (done nil))
    (unwind-protect
        (lispm-kernel-test--with-runtime runtime
          (lispm-kernel-test--wait runtime (lambda () (lispm-kernel-runtime-hello runtime)))
          (let ((lispm-kernel-exec-runtime-function (lambda () runtime)))
            (should (lispm-kernel-feature-p runtime :sse-decode))
            (lispm-kernel-llm-stream
             'anthropic (concat (cdr srv) "/v1/messages")
             '("content-type: application/json") "{\"messages\":[]}"
             (lambda (kind val) (push (list kind val) deltas))
             (lambda (res) (setq done res)))
            (should (lispm-kernel-test--wait runtime (lambda () done)))
            (should (eq t (plist-get done :ok)))
            (should (string= "hello kernel"
                             (mapconcat #'cadr
                                        (cl-remove-if-not (lambda (d) (eq (car d) 'text))
                                                          (nreverse deltas))
                                        "")))))
      (lispm-kernel-agent-test--stop-server srv))))

(ert-deftest lispm-kernel-agent-effect-rpc-and-socket-reconnect ()
  "Verify real `lispm-kernel --socket' survives Emacs detach mid-turn and resyncs."
  (let* ((dir (make-temp-file "lispm-kagent" t))
         (sock (format "/tmp/lk-el-test-%d-%d.sock" (emacs-pid) (random 100000)))
         (srv nil)
         (daemon nil))
    (unwind-protect
        (progn
          (setq srv
                (lispm-kernel-agent-test--start-sse-server
                 (lambda (body proc)
                   (if (string-search "eval-ok" body)
                       (lispm-kernel-agent-test--send-sse
                        proc
                        (concat
                         "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\"}}\n\n"
                         "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
                         "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"final-ok\"}}\n\n"
                         "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n"
                         "data: {\"type\":\"message_stop\"}\n\n"))
                     ;; Emit an eval_elisp tool_use on first request after slight SSE header write
                     (lispm-kernel-agent-test--send-sse
                      proc
                      (concat
                       "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\"}}\n\n"
                       "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_e\",\"name\":\"eval_elisp\",\"input\":{}}}\n\n"
                       "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"code\\\":\\\"'eval-ok\\\"}\"}}\n\n"
                       "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
                       "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}\n\n"
                       "data: {\"type\":\"message_stop\"}\n\n"))))))
          (let ((ready nil))
            (setq daemon
                  (make-process
                   :name "lispm-kernel-sock-daemon"
                   :command (list lispm-kernel-test-program "--socket" sock)
                   :connection-type 'pipe
                   :noquery t
                   :filter (lambda (_p s) (when (string-search "listening" s) (setq ready t)))))
            (let ((dl (+ (float-time) 10)))
              (while (and (not (and ready (file-exists-p sock))) (< (float-time) dl))
                (accept-process-output nil 0.01)))
            (should (file-exists-p sock))
            ;; First connection: start agent, handle eval_elisp effect, detach BEFORE next check
            (let* ((rt1 (lispm-kernel-connect sock))
                   (events1 nil)
                   (effect-seen nil))
              (setf (lispm-kernel-runtime-event-handler rt1)
                    (lambda (msg)
                      (push msg events1)
                      (when (eq (car msg) 'editor-effect-request)
                        (setq effect-seen msg))))
              (should (lispm-kernel-test--wait rt1 (lambda () (lispm-kernel-runtime-hello rt1))))
              (should (lispm-kernel-feature-p rt1 :socket-reconnect))
              (lispm-kernel-agent-start rt1 "sess-1"
                                        (list :dialect :anthropic
                                              :url (concat (cdr srv) "/v1/messages")
                                              :root dir
                                              :tool-policies '(:auto ("eval_elisp"))))
              (lispm-kernel-agent-turn rt1 "sess-1"
                                       (list :turn-id "t1"
                                             :body "{\"messages\":[{\"role\":\"user\",\"content\":\"go\"}]}"))
              (should (lispm-kernel-test--wait rt1 (lambda () effect-seen)))
              ;; Reply to effect and immediately detach socket!
              (lispm-kernel-agent-effect-reply rt1 "sess-1" (nth 2 effect-seen) :ok "eval-ok")
              (lispm-kernel-detach rt1))
            ;; Second connection: poll resync until detached background turn completes!
            (let* ((rt2 (lispm-kernel-connect sock))
                   (snap nil)
                   (deadline (+ (float-time) 10)))
              (setf (lispm-kernel-runtime-event-handler rt2)
                    (lambda (msg)
                      (when (eq (car msg) 'agent-snapshot)
                        (setq snap (nth 2 msg)))))
              (should (lispm-kernel-test--wait rt2 (lambda () (lispm-kernel-runtime-hello rt2))))
              (while (and (not (and snap (eq (plist-get snap :state) :idle)))
                          (< (float-time) deadline))
                (setq snap nil)
                (lispm-kernel-agent-resync rt2 "sess-1" 0)
                (lispm-kernel-test--wait rt2 (lambda () snap) 2)
                (unless (and snap (eq (plist-get snap :state) :idle))
                  (accept-process-output nil 0.05)))
              (should snap)
              (should (eq (plist-get snap :state) :idle))
              (should (integerp (plist-get snap :epoch)))
              (should (string= "final-ok" (plist-get (plist-get snap :stream) :text)))
              (should (= 1 (length (plist-get snap :completed-turns))))
              (lispm-kernel-quit rt2))))
      (when (process-live-p daemon) (delete-process daemon))
      (lispm-kernel-agent-test--stop-server srv)
      (ignore-errors (delete-file sock))
      (delete-directory dir t))))

(provide 'lispm-kernel-agent-test)
;;; lispm-kernel-agent-test.el ends here
