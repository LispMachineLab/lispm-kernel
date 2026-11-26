;;;; sse-test.lisp --- Tests of lossless JSON encoding and SSE decoding

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

(deftest json-lossless-roundtrip ()
  (let* ((src "{\"flag\":false,\"empty\":[],\"nothing\":null,\"ok\":true,\"nested\":[1,-2.5,{\"txt\":\"a\\nb\\\"c\"}]}")
         (parsed (parse-json src :preserve-literals t))
         (reencoded (encode-json parsed))
         (reparsed (parse-json reencoded :preserve-literals t)))
    (is (eq :false (json-get reparsed "flag")))
    (is (equalp #() (json-get reparsed "empty")))
    (is (eq :null (json-get reparsed "nothing")))
    (is (eq t (json-get reparsed "ok")))
    (is (string= (format nil "a~%b\"c")
                 (json-get (aref (json-get reparsed "nested") 2) "txt")))
    (is (string= "1e-5"
                 (json-number-text
                  (aref (json-get (parse-json (encode-json (parse-json "{\"x\":[1e-5]}" :preserve-literals t))
                                              :preserve-literals t)
                                  "x")
                        0))))
    (signals json-error (parse-json "["))))

(deftest json-lossless-number-array ()
  (let* ((arr (parse-json "[1e-5,true,false,null,[]]" :preserve-literals t))
         (re (encode-json arr))
         (back (parse-json re :preserve-literals t)))
    (is (string= "1e-5" (json-number-text (aref back 0))))
    (is (eq t (aref back 1)))
    (is (eq :false (aref back 2)))
    (is (eq :null (aref back 3)))
    (is (equalp #() (aref back 4)))))

(deftest sse-anthropic-streaming-and-tools ()
  (let* ((dec (lispm-kernel:make-sse-decoder :anthropic))
         (ev1 (concatenate
               'string
               "event: message_start" (string #\Newline)
               "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"model\":\"claude-x\",\"usage\":{\"input_tokens\":10,\"cache_read_input_tokens\":4}}}" (string #\Newline) (string #\Newline)
               "event: content_block_start" (string #\Newline)
               "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}" (string #\Newline) (string #\Newline)
               "event: content_block_delta" (string #\Newline)
               "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"hmm \"}}" (string #\Newline) (string #\Newline)
               "event: content_block_delta" (string #\Newline)))
         (ev2 (concatenate
               'string
               "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"ok\"}}" (string #\Newline) (string #\Newline)
               "event: content_block_delta" (string #\Newline)
               "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig1\"}}" (string #\Newline) (string #\Newline)
               "event: content_block_stop" (string #\Newline)
               "data: {\"type\":\"content_block_stop\",\"index\":0}" (string #\Newline) (string #\Newline)
               "event: content_block_start" (string #\Newline)
               "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}" (string #\Newline) (string #\Newline)
               "event: content_block_delta" (string #\Newline)
               "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hel\"}}" (string #\Newline) (string #\Newline)
               "event: content_block_delta" (string #\Newline)
               "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}" (string #\Newline) (string #\Newline)
               "event: content_block_start" (string #\Newline)
               "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"run_shell\",\"input\":{}}}" (string #\Newline) (string #\Newline)
               "event: content_block_delta" (string #\Newline)
               "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"echo hi\\\"}\"}}" (string #\Newline) (string #\Newline)
               "event: content_block_stop" (string #\Newline)
               "data: {\"type\":\"content_block_stop\",\"index\":2}" (string #\Newline) (string #\Newline)
               "event: message_delta" (string #\Newline)
               "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":19}}" (string #\Newline) (string #\Newline)
               "event: message_stop" (string #\Newline)
               "data: {\"type\":\"message_stop\"}" (string #\Newline) (string #\Newline)
               lispm-kernel::*http-status-marker* "200" (string #\Newline)))
         (d1 (lispm-kernel:sse-feed dec ev1 :coalesce t))
         (d2 (lispm-kernel:sse-feed dec ev2 :coalesce t))
         (res (lispm-kernel:sse-finish dec '(:exit 0 :stderr ""))))
    (is (equal '((:delta :thinking "hmm ")) d1))
    (is (equal '(:delta :thinking "ok") (first d2)))
    (is (equal '(:delta :text "Hello") (second d2)))
    (is (equal '(:delta :tool "run_shell") (third d2)))
    (is (eq t (getf res :ok)))
    (is (eql 200 (getf res :status)))
    (is (string= "tool_use" (getf res :stop-reason)))
    (is (= 10 (getf (getf res :usage) :input-tokens)))
    (is (= 19 (getf (getf res :usage) :output-tokens)))
    (is (= 4 (getf (getf res :usage) :cache-read-input-tokens)))
    (is (null (getf res :invalid)))
    (let ((blocks (getf res :blocks)))
      (is (= 3 (length blocks)))
      (is (string= "hmm ok" (getf (first blocks) :thinking)))
      (is (string= "sig1" (getf (first blocks) :signature)))
      (is (string= "Hello" (getf (second blocks) :text)))
      (is (string= "tu_1" (getf (third blocks) :id)))
      (is (string= "run_shell" (getf (third blocks) :name)))
      (is (string= "{\"command\":\"echo hi\"}" (getf (third blocks) :input-json))))))

(deftest sse-anthropic-invalid-tool-json-and-fallback ()
  (let* ((dec (lispm-kernel:make-sse-decoder :anthropic))
         (stream-body
           (concatenate
            'string
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"drop me\"}}" (string #\Newline) (string #\Newline)
            "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"keep pre\"}}" (string #\Newline) (string #\Newline)
            "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"fallback\"}}" (string #\Newline) (string #\Newline)
            "data: {\"type\":\"content_block_start\",\"index\":3,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_bad\",\"name\":\"run_shell\",\"input\":{}}}" (string #\Newline) (string #\Newline)
            "data: {\"type\":\"content_block_delta\",\"index\":3,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{bad json\"}}" (string #\Newline) (string #\Newline)
            "data: {\"type\":\"content_block_stop\",\"index\":3}" (string #\Newline) (string #\Newline)
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}" (string #\Newline) (string #\Newline)
            "data: {\"type\":\"message_stop\"}" (string #\Newline) (string #\Newline)
            lispm-kernel::*http-status-marker* "200" (string #\Newline))))
    (lispm-kernel:sse-feed dec stream-body)
    (let ((res (lispm-kernel:sse-finish dec '(:exit 0 :stderr ""))))
      (is (eq t (getf res :ok)))
      (is (equal '("tu_bad") (getf res :invalid)))
      ;; Pre-fallback thinking dropped; pre-fallback text kept!
      (is (= 3 (length (getf res :blocks))))
      (is (eq :text (getf (first (getf res :blocks)) :type)))
      (is (string= "keep pre" (getf (first (getf res :blocks)) :text))))))

(deftest sse-openai-streaming-whole-and-errors ()
  ;; Streaming OpenAI with cached tokens & reasoning
  (let* ((dec (lispm-kernel:make-sse-decoder :openai))
         (chunk
           (concatenate
            'string
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"think\"}}]}" (string #\Newline) (string #\Newline)
            "data: {\"choices\":[{\"delta\":{\"content\":\"hi there\"}}]}" (string #\Newline) (string #\Newline)
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read_file\",\"arguments\":\"{\\\"path\\\":\\\"a.txt\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}" (string #\Newline) (string #\Newline)
            "data: {\"usage\":{\"prompt_tokens\":100,\"completion_tokens\":20,\"prompt_tokens_details\":{\"cached_tokens\":30}}}" (string #\Newline) (string #\Newline)
            "data: [DONE]" (string #\Newline) (string #\Newline)
            lispm-kernel::*http-status-marker* "200" (string #\Newline)))
         (deltas (lispm-kernel:sse-feed dec chunk :coalesce t))
         (res (lispm-kernel:sse-finish dec '(:exit 0 :stderr ""))))
    (is (equal '(:delta :thinking "think") (first deltas)))
    (is (equal '(:delta :text "hi there") (second deltas)))
    (is (equal '(:delta :tool "read_file") (third deltas)))
    (is (eq t (getf res :ok)))
    (is (string= "tool_use" (getf res :stop-reason)))
    (is (= 70 (getf (getf res :usage) :input-tokens)))
    (is (= 30 (getf (getf res :usage) :cache-read-input-tokens)))
    (is (= 20 (getf (getf res :usage) :output-tokens)))
    (is (= 3 (length (getf res :blocks)))))
  ;; OpenAI streaming `:null' fields (`tool_calls: null`, `choices: null`) never crash
  (let* ((dec-null (lispm-kernel:make-sse-decoder :openai))
         (chunk-null
           (concatenate
            'string
            "data: {\"choices\":null}" (string #\Newline) (string #\Newline)
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\",\"tool_calls\":null},\"finish_reason\":\"stop\"}]}" (string #\Newline) (string #\Newline)
            "data: [DONE]" (string #\Newline) (string #\Newline)
            lispm-kernel::*http-status-marker* "200" (string #\Newline))))
    (lispm-kernel:sse-feed dec-null chunk-null :coalesce t)
    (let ((res (lispm-kernel:sse-finish dec-null '(:exit 0 :stderr ""))))
      (is (eq t (getf res :ok)))
      (is (string= "ok" (getf (first (getf res :blocks)) :text)))))
  ;; Non-streamed OpenAI `:null' arguments & `:tool-input' batching
  (let ((dec-args (lispm-kernel:make-sse-decoder :openai)))
    (lispm-kernel:sse-feed
     dec-args
     (concatenate 'string
                  "{\"choices\":[{\"message\":{\"tool_calls\":[{\"id\":\"c1\",\"function\":{\"name\":\"list_buffers\",\"arguments\":null}}]},\"finish_reason\":\"tool_calls\"}]}"
                  lispm-kernel::*http-status-marker* "200" (string #\Newline)))
    (let ((res (lispm-kernel:sse-finish dec-args '(:exit 0 :stderr ""))))
      (is (eq t (getf res :ok)))
      (is (string= "{}" (getf (first (getf res :blocks)) :input-json)))))
  ;; Non-streamed whole JSON response + HTTP 429 error
  (let ((dec-whole (lispm-kernel:make-sse-decoder :openai)))
    (lispm-kernel:sse-feed
     dec-whole
     (concatenate 'string
                  "{\"choices\":[{\"message\":{\"content\":\"whole reply\"},\"finish_reason\":\"stop\"}]}"
                  lispm-kernel::*http-status-marker* "200" (string #\Newline)))
    (let ((res (lispm-kernel:sse-finish dec-whole '(:exit 0 :stderr ""))))
      (is (eq t (getf res :ok)))
      (is (string= "whole reply" (getf (first (getf res :blocks)) :text)))))
  (let ((dec-err (lispm-kernel:make-sse-decoder :anthropic)))
    (lispm-kernel:sse-feed
     dec-err
     (concatenate 'string
                  "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}"
                  lispm-kernel::*http-status-marker* "429" (string #\Newline)))
    (let ((res (lispm-kernel:sse-finish dec-err '(:exit 0 :stderr ""))))
      (is (eq nil (getf res :ok)))
      (is (= 429 (getf res :status)))
      (is (string= "rate_limit_error" (getf res :type)))
      (is (string= "slow down" (getf res :message))))))

(deftest sse-tool-input-batching-and-other-block-json ()
  ;; Multi-chunk `input_json_delta' emits once per `sse-feed', or 0 times when `:emit-tool-input nil'
  (let* ((dec1 (lispm-kernel:make-sse-decoder :anthropic))
         (ev (concatenate
              'string
              "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"enc\"}}" (string #\Newline) (string #\Newline)
              "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"run_shell\",\"input\":{}}}" (string #\Newline) (string #\Newline)
              "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"a\\\":\"}}" (string #\Newline) (string #\Newline)
              "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"1}\"}}" (string #\Newline) (string #\Newline)
              "data: {\"type\":\"content_block_stop\",\"index\":1}" (string #\Newline) (string #\Newline)
              "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}" (string #\Newline) (string #\Newline)
              "data: {\"type\":\"message_stop\"}" (string #\Newline) (string #\Newline)
              lispm-kernel::*http-status-marker* "200" (string #\Newline)))
         (d1 (lispm-kernel:sse-feed dec1 ev :coalesce t :emit-tool-input t))
         (res1 (lispm-kernel:sse-finish dec1 '(:exit 0 :stderr ""))))
    (is (= 1 (count :tool-input d1 :key #'second)))
    (is (string= "enc" (json-get (parse-json (getf (first (getf res1 :blocks)) :json)) "data")))
    (let* ((dec2 (lispm-kernel:make-sse-decoder :anthropic))
           (d2 (lispm-kernel:sse-feed dec2 ev :coalesce t :emit-tool-input nil)))
      (is (= 0 (count :tool-input d2 :key #'second))))))
