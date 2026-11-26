;;;; sse.lisp --- Off-thread SSE decoding and Messages normalization

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

;;; Incremental, pure-per-stream decoder for Anthropic Messages and
;;; OpenAI Chat Completions HTTP SSE streams.  Runs off Emacs's main
;;; thread (inside `P_reactor' chunk/finish transforms or `P_agents'),
;;; emitting wire-safe delta plists and a canonical Messages-shape
;;; summary without dotted pairs or floats.

(in-package #:lispm-kernel)

(defparameter *sse-raw-limit* (* 2 1024 1024)
  "Soft byte budget for retained non-streaming head text in an `sse-decoder'.")

(defparameter *sse-tail-limit* 512
  "Trailing characters always retained so `*http-status-marker*' is intact.")

(defstruct (sse-block (:constructor make-sse-block (type &key id name ephemeral raw-json))
                      (:copier nil))
  "Mutable accumulation state for one content block within one `sse-decoder'."
  (type "" :type string)
  (id nil :type (or null string))
  (name nil :type (or null string))
  (ephemeral nil :type boolean)
  (raw-json nil :type (or null string))
  (text-chunks '() :type list)
  (thinking-chunks '() :type list)
  (signature-chunks '() :type list)
  (json-chunks '() :type list)
  (fallback-json nil :type (or null string)))

(defstruct (sse-decoder (:constructor %make-sse-decoder (dialect)) (:copier nil))
  "Incremental per-stream state owned by one reactor slot or agent actor."
  (dialect :anthropic :type (member :anthropic :openai) :read-only t)
  (pending "" :type string)
  (head (make-string-output-stream))
  (head-len 0 :type fixnum)
  (tail "" :type string)
  (started nil :type boolean)
  (done nil :type boolean)
  (message-id nil :type (or null string))
  (model nil :type (or null string))
  (stop-reason nil :type (or null string))
  (usage nil :type list)
  (openai-usage nil)
  (error nil :type list)
  (client-error nil :type list)
  (blocks (make-hash-table :test 'eql) :type hash-table :read-only t)
  (text-index nil :type (or null integer))
  (thinking-index nil :type (or null integer))
  (next-synthetic-id 0 :type fixnum)
  (invalid '() :type list))

(defun make-sse-decoder (dialect)
  "Create a fresh `sse-decoder' for DIALECT (`:anthropic' or `:openai')."
  (check-type dialect (member :anthropic :openai))
  (%make-sse-decoder dialect))

;;;; Small string and JSON helpers

(defun sse-nonempty-string (value)
  "Return VALUE if it is a non-empty string, else nil."
  (and (stringp value) (plusp (length value)) value))

(defun sse-json-list (value)
  "Return list elements from JSON array VALUE (list or vector), else nil."
  (cond ((listp value) value)
        ((vectorp value) (coerce value 'list))
        (t '())))

(defun sse-json-present-p (value)
  "Return true when parsed JSON VALUE is non-nil and not `:null'."
  (and value (not (eq value :null))))

(defun sse-string-trim (string)
  "Trim ASCII whitespace from both ends of STRING."
  (string-trim '(#\Space #\Tab #\Newline #\Return) string))

(defun sse-truncate (string limit)
  "Shorten STRING to at most LIMIT characters with a middle omission marker."
  (let ((len (length string)))
    (if (<= len limit)
        string
        (let ((head (floor (* limit 6) 10))
              (tail (floor (* limit 4) 10)))
          (concatenate 'string
                       (subseq string 0 head)
                       (format nil "~%~%[... ~D characters omitted ...]~%~%"
                               (- len head tail))
                       (subseq string (- len tail)))))))

(defun sse-json-integer (value)
  "Convert parsed JSON numeric VALUE (or integer) into a CL integer, or nil."
  (cond ((integerp value) value)
        ((lispm-kernel/json:json-number-p value)
         (let* ((text (lispm-kernel/json:json-number-text value))
                (dot (or (position #\. text) (position #\e text) (position #\E text)))
                (slice (if dot (subseq text 0 dot) text)))
           (when (plusp (length slice))
             (handler-case (parse-integer slice)
               (parse-error () nil)))))
        (t nil)))

(defun sse-join-chunks (chunks)
  "Join reversed string list CHUNKS into a single string."
  (let ((ordered (reverse chunks)))
    (cond ((null ordered) "")
          ((null (rest ordered)) (first ordered))
          (t (apply #'concatenate 'string ordered)))))

(defun sse-record-raw (decoder chunk)
  "Retain HEAD (bounded) and sliding TAIL of raw HTTP output on DECODER."
  (when (plusp (length chunk))
    (let* ((room (max 0 (- *sse-raw-limit* (sse-decoder-head-len decoder)))))
      (when (plusp room)
        (let ((take (min room (length chunk))))
          (write-string chunk (sse-decoder-head decoder) :end take)
          (incf (sse-decoder-head-len decoder) take))))
    (let ((combined (concatenate 'string (sse-decoder-tail decoder) chunk)))
      (setf (sse-decoder-tail decoder)
            (if (> (length combined) *sse-tail-limit*)
                (subseq combined (- (length combined) *sse-tail-limit*))
                combined)))))

(defun sse-line-end-length (text pos len)
  "Return line-ending byte count (1 or 2) at POS in TEXT of LEN, or nil."
  (when (< pos len)
    (cond ((char= (char text pos) #\Newline) 1)
          ((and (char= (char text pos) #\Return)
                (< (1+ pos) len)
                (char= (char text (1+ pos)) #\Newline))
           2)
          (t nil))))

(defun sse-find-event-end (text from len)
  "Return (values END-POS NEXT-START) of first blank line at/after FROM, or nils."
  (loop for i from from below len
        for first-len = (sse-line-end-length text i len)
        when first-len
          do (let ((second-len (sse-line-end-length text (+ i first-len) len)))
               (when second-len
                 (return-from sse-find-event-end
                   (values i (+ i first-len second-len))))))
  (values nil nil))

(defun sse-extract-data (block)
  "Extract joined `data:' lines from one SSE event BLOCK, or nil."
  (let ((blen (length block))
        (pos 0)
        (parts '()))
    (loop while (< pos blen)
          do (let ((eol (or (position #\Newline block :start pos) blen)))
               (let ((end eol))
                 (when (and (> end pos) (char= (char block (1- end)) #\Return))
                   (decf end))
                 (when (and (>= (- end pos) 5)
                            (string= block "data:" :start1 pos :end1 (+ pos 5)))
                   (let ((dstart (+ pos 5)))
                     (when (and (< dstart end) (char= (char block dstart) #\Space))
                       (incf dstart))
                     (push (subseq block dstart end) parts))))
               (setf pos (1+ eol))))
    (when parts
      (let ((joined (apply #'concatenate 'string
                           (loop for (p . more) on (nreverse parts)
                                 collect p
                                 when more collect (string #\Newline)))))
        (when (plusp (length joined))
          joined)))))

(defun sse-split-events (text)
  "Split SSE buffer TEXT by blank lines; return (values EVENT-DATA-STRINGS REST)."
  (let ((len (length text))
        (start 0)
        (events '()))
    (loop
      (multiple-value-bind (ev-end next-start) (sse-find-event-end text start len)
        (unless ev-end
          (return (values (nreverse events) (subseq text start))))
        (let ((payload (sse-extract-data (subseq text start ev-end))))
          (when payload
            (push payload events)))
        (setf start next-start)))))

;;;; Usage & error normalization helpers

(defun sse-merge-anthropic-usage (current json-usage)
  "Merge Anthropic JSON-USAGE object into usage plist CURRENT."
  (when (lispm-kernel/json:json-object-p json-usage)
    (let ((out (copy-list current)))
      (dolist (spec '(("input_tokens" . :input-tokens)
                      ("output_tokens" . :output-tokens)
                      ("cache_read_input_tokens" . :cache-read-input-tokens)
                      ("cache_creation_input_tokens" . :cache-creation-input-tokens)))
        (let ((val (sse-json-integer (lispm-kernel/json:json-get json-usage (car spec)))))
          (when val
            (setf (getf out (cdr spec)) val))))
      out)))

(defun sse-convert-openai-usage (json-usage)
  "Convert OpenAI JSON-USAGE object into canonical usage plist, or nil."
  (when (lispm-kernel/json:json-object-p json-usage)
    (let* ((details (lispm-kernel/json:json-get json-usage "prompt_tokens_details"))
           (prompt (sse-json-integer (lispm-kernel/json:json-get json-usage "prompt_tokens")))
           (completion (sse-json-integer (lispm-kernel/json:json-get json-usage "completion_tokens")))
           (cached (or (sse-json-integer (lispm-kernel/json:json-get details "cached_tokens"))
                       (sse-json-integer (lispm-kernel/json:json-get json-usage "cached_tokens"))
                       (sse-json-integer (lispm-kernel/json:json-get json-usage "prompt_cache_hit_tokens"))))
           (created (or (sse-json-integer (lispm-kernel/json:json-get details "cache_write_tokens"))
                        (sse-json-integer (lispm-kernel/json:json-get details "cache_creation_input_tokens"))
                        (sse-json-integer (lispm-kernel/json:json-get json-usage "cache_creation_input_tokens"))
                        (sse-json-integer (lispm-kernel/json:json-get json-usage "cache_write_tokens"))))
           (out '()))
      (when (and created (<= created 0))
        (setf created nil))
      (when created
        (setf (getf out :cache-creation-input-tokens) created))
      (when cached
        (setf (getf out :cache-read-input-tokens) cached))
      (when completion
        (setf (getf out :output-tokens) completion))
      (when prompt
        (setf (getf out :input-tokens) (if cached (- prompt cached) prompt)))
      out)))

(defun sse-error-plist (status err)
  "Normalize ERR (a `json-object' or string) and HTTP STATUS into a plist."
  (list :ok nil
        :status (or status 0)
        :type (or (sse-nonempty-string (lispm-kernel/json:json-get err "type"))
                  (let ((code (lispm-kernel/json:json-get err "code")))
                    (and (sse-json-present-p code) (princ-to-string code)))
                  "http_error")
        :message (cond ((stringp err) err)
                       ((sse-nonempty-string (lispm-kernel/json:json-get err "message")))
                       (t (sse-truncate (princ-to-string err) 500)))))

;;;; Block materialization & Anthropic / OpenAI event application

(defun sse-coalesce-deltas (deltas)
  "Merge adjacent `:text' or `:thinking' delta plists in DELTAS."
  (let ((out '()))
    (dolist (ev deltas (nreverse out))
      (let ((prev (first out)))
        (if (and prev
                 (eq (first ev) :delta)
                 (eq (first prev) :delta)
                 (member (second ev) '(:text :thinking))
                 (eq (second ev) (second prev)))
            (setf (third prev) (concatenate 'string (third prev) (third ev)))
            (push (copy-list ev) out))))))

(defun sse-valid-json-string-p (text)
  "Return true when TEXT is valid RFC 8259 JSON matching Emacs's rules."
  (handler-case
      (progn
        (lispm-kernel/json:parse-json text :preserve-literals t)
        t)
    (lispm-kernel/json:json-error () nil)))

(defun sse-ensure-block (decoder index type &key id name ephemeral raw-json)
  "Return DECODER's `sse-block' at INDEX, creating one if absent."
  (or (gethash index (sse-decoder-blocks decoder))
      (setf (gethash index (sse-decoder-blocks decoder))
            (make-sse-block type :id id :name name :ephemeral ephemeral :raw-json raw-json))))

(defun sse-anthropic-message-start (decoder ev)
  "Apply Anthropic `message_start' event EV to DECODER."
  (let ((msg (lispm-kernel/json:json-get ev "message")))
    (when (lispm-kernel/json:json-object-p msg)
      (setf (sse-decoder-message-id decoder) (sse-nonempty-string (lispm-kernel/json:json-get msg "id"))
            (sse-decoder-model decoder) (sse-nonempty-string (lispm-kernel/json:json-get msg "model"))
            (sse-decoder-stop-reason decoder) (sse-nonempty-string (lispm-kernel/json:json-get msg "stop_reason")))
      (let ((usage (sse-merge-anthropic-usage (sse-decoder-usage decoder)
                                              (lispm-kernel/json:json-get msg "usage"))))
        (when usage (setf (sse-decoder-usage decoder) usage))))))

(defun sse-anthropic-block-start (decoder ev index emit-fn)
  "Apply Anthropic `content_block_start' event EV at INDEX to DECODER."
  (let* ((cb (lispm-kernel/json:json-get ev "content_block"))
         (btype (or (sse-nonempty-string (lispm-kernel/json:json-get cb "type")) ""))
         (id (sse-nonempty-string (lispm-kernel/json:json-get cb "id")))
         (name (sse-nonempty-string (lispm-kernel/json:json-get cb "name")))
         (known-p (or (equal btype "text") (equal btype "thinking") (equal btype "tool_use")))
         (raw-json (when (and (not known-p) (lispm-kernel/json:json-object-p cb))
                     (lispm-kernel/json:encode-json cb)))
         (block (make-sse-block btype :id id :name name :raw-json raw-json))
         (init-text (lispm-kernel/json:json-get cb "text"))
         (init-thinking (lispm-kernel/json:json-get cb "thinking"))
         (init-sig (lispm-kernel/json:json-get cb "signature"))
         (init-input (lispm-kernel/json:json-get cb "input")))
    (when (stringp init-text) (push init-text (sse-block-text-chunks block)))
    (when (stringp init-thinking) (push init-thinking (sse-block-thinking-chunks block)))
    (when (stringp init-sig) (push init-sig (sse-block-signature-chunks block)))
    (when (lispm-kernel/json:json-object-p init-input)
      (setf (sse-block-fallback-json block)
            (lispm-kernel/json:encode-json init-input)))
    (when index
      (setf (gethash index (sse-decoder-blocks decoder)) block))
    (when (and (equal btype "tool_use") name)
      (funcall emit-fn (list :delta :tool name)))))

(defun sse-anthropic-block-delta (decoder ev index emit-fn mark-dirty-fn)
  "Apply Anthropic `content_block_delta' event EV at INDEX to DECODER."
  (let* ((block (and index (gethash index (sse-decoder-blocks decoder))))
         (delta (lispm-kernel/json:json-get ev "delta"))
         (dtype (lispm-kernel/json:json-get delta "type")))
    (when block
      (cond
        ((equal dtype "text_delta")
         (let ((text (lispm-kernel/json:json-get delta "text")))
           (when (stringp text)
             (push text (sse-block-text-chunks block))
             (funcall emit-fn (list :delta :text text)))))
        ((equal dtype "thinking_delta")
         (let ((text (lispm-kernel/json:json-get delta "thinking")))
           (when (stringp text)
             (push text (sse-block-thinking-chunks block))
             (funcall emit-fn (list :delta :thinking text)))))
        ((equal dtype "signature_delta")
         (let ((sig (lispm-kernel/json:json-get delta "signature")))
           (when (stringp sig)
             (push sig (sse-block-signature-chunks block)))))
        ((equal dtype "input_json_delta")
         (let ((part (lispm-kernel/json:json-get delta "partial_json")))
           (when (stringp part)
             (push part (sse-block-json-chunks block))
             (when mark-dirty-fn
               (funcall mark-dirty-fn block)))))))))

(defun sse-anthropic-block-stop (decoder index)
  "Validate completed `tool_use' JSON on `content_block_stop' at INDEX."
  (let ((block (and index (gethash index (sse-decoder-blocks decoder)))))
    (when (and block (equal (sse-block-type block) "tool_use"))
      (let ((raw-json (sse-string-trim (sse-join-chunks (sse-block-json-chunks block)))))
        (when (and (plusp (length raw-json))
                   (not (sse-valid-json-string-p raw-json))
                   (sse-block-id block))
          (pushnew (sse-block-id block) (sse-decoder-invalid decoder) :test #'string=))))))

(defun sse-anthropic-message-delta (decoder ev)
  "Apply Anthropic `message_delta' stop_reason and usage updates."
  (let ((delta (lispm-kernel/json:json-get ev "delta"))
        (usage (lispm-kernel/json:json-get ev "usage")))
    (when (lispm-kernel/json:json-object-p delta)
      (let ((sr (sse-nonempty-string (lispm-kernel/json:json-get delta "stop_reason"))))
        (when sr (setf (sse-decoder-stop-reason decoder) sr))))
    (when (lispm-kernel/json:json-object-p usage)
      (setf (sse-decoder-usage decoder)
            (sse-merge-anthropic-usage (sse-decoder-usage decoder) usage)))))

(defun sse-apply-anthropic-event (decoder ev emit-fn &optional mark-dirty-fn)
  "Apply one decoded Anthropic SSE event JSON object EV to DECODER."
  (let ((ev-type (lispm-kernel/json:json-get ev "type"))
        (index (sse-json-integer (lispm-kernel/json:json-get ev "index"))))
    (cond
      ((equal ev-type "message_start")
       (setf (sse-decoder-started decoder) t)
       (sse-anthropic-message-start decoder ev))
      ((equal ev-type "content_block_start")
       (setf (sse-decoder-started decoder) t)
       (sse-anthropic-block-start decoder ev index emit-fn))
      ((equal ev-type "content_block_delta")
       (setf (sse-decoder-started decoder) t)
       (sse-anthropic-block-delta decoder ev index emit-fn mark-dirty-fn))
      ((equal ev-type "content_block_stop")
       (sse-anthropic-block-stop decoder index))
      ((equal ev-type "message_delta")
       (setf (sse-decoder-started decoder) t)
       (sse-anthropic-message-delta decoder ev))
      ((equal ev-type "message_stop")
       (setf (sse-decoder-started decoder) t
             (sse-decoder-done decoder) t))
      ((equal ev-type "error")
       (setf (sse-decoder-started decoder) t)
       (let ((err (lispm-kernel/json:json-get ev "error")))
         (setf (sse-decoder-error decoder)
               (list :type (or (sse-nonempty-string (lispm-kernel/json:json-get err "type"))
                               "api_error")
                     :message (or (sse-nonempty-string (lispm-kernel/json:json-get err "message"))
                                  "API stream error"))))))))

(defun sse-openai-finish-to-stop (finish)
  "Map OpenAI `finish_reason' FINISH to Messages `stop_reason'."
  (cond ((or (equal finish "tool_calls") (equal finish "function_call")) "tool_use")
        ((equal finish "length") "max_tokens")
        ((equal finish "content_filter") "refusal")
        (t "end_turn")))

(defun sse-openai-apply-tool-call (decoder call emit-fn mark-dirty-fn)
  "Apply one OpenAI delta `tool_calls' item CALL onto DECODER."
  (let* ((raw-idx (or (sse-json-integer (lispm-kernel/json:json-get call "index")) 0))
         ;; Offset tool indices by +1000 so synthetic thinking(0)/text(1) never collide.
         (slot-idx (+ 1000 raw-idx))
         (block (sse-ensure-block decoder slot-idx "tool_use"))
         (fn (lispm-kernel/json:json-get call "function"))
         (id (sse-nonempty-string (lispm-kernel/json:json-get call "id")))
         (name (and (lispm-kernel/json:json-object-p fn)
                    (sse-nonempty-string (lispm-kernel/json:json-get fn "name"))))
         (args (and (lispm-kernel/json:json-object-p fn)
                    (lispm-kernel/json:json-get fn "arguments"))))
    (when id (setf (sse-block-id block) id))
    (when (and name (null (sse-block-name block)))
      (setf (sse-block-name block) name)
      (funcall emit-fn (list :delta :tool name)))
    (when (stringp args)
      (push args (sse-block-json-chunks block))
      (when (and (sse-block-name block) mark-dirty-fn)
        (funcall mark-dirty-fn block)))))

(defun sse-apply-openai-chunk (decoder chunk emit-fn &optional mark-dirty-fn)
  "Apply one decoded OpenAI Chat Completions chunk onto DECODER."
  (setf (sse-decoder-started decoder) t)
  (let ((err (lispm-kernel/json:json-get chunk "error")))
    (when (sse-json-present-p err)
      (setf (sse-decoder-error decoder)
            (let ((pl (sse-error-plist 200 err)))
              (list :type (getf pl :type) :message (getf pl :message))))))
  (let ((usage (lispm-kernel/json:json-get chunk "usage")))
    (when (lispm-kernel/json:json-object-p usage)
      (setf (sse-decoder-openai-usage decoder) usage)))
  (dolist (choice (sse-json-list (lispm-kernel/json:json-get chunk "choices")))
    (let ((delta (lispm-kernel/json:json-get choice "delta"))
          (finish (lispm-kernel/json:json-get choice "finish_reason")))
      (when (lispm-kernel/json:json-object-p delta)
        (let ((thought (or (sse-nonempty-string (lispm-kernel/json:json-get delta "reasoning_content"))
                           (sse-nonempty-string (lispm-kernel/json:json-get delta "reasoning")))))
          (when thought
            (let* ((idx (or (sse-decoder-thinking-index decoder)
                            (setf (sse-decoder-thinking-index decoder) 0)))
                   (block (sse-ensure-block decoder idx "thinking" :ephemeral t)))
              (push thought (sse-block-thinking-chunks block))
              (funcall emit-fn (list :delta :thinking thought)))))
        (let ((text (sse-nonempty-string (lispm-kernel/json:json-get delta "content"))))
          (when text
            (let* ((idx (or (sse-decoder-text-index decoder)
                            (setf (sse-decoder-text-index decoder) 1)))
                   (block (sse-ensure-block decoder idx "text")))
              (push text (sse-block-text-chunks block))
              (funcall emit-fn (list :delta :text text)))))
        (dolist (call (sse-json-list (lispm-kernel/json:json-get delta "tool_calls")))
          (sse-openai-apply-tool-call decoder call emit-fn mark-dirty-fn)))
      (when (stringp finish)
        (setf (sse-decoder-stop-reason decoder) (sse-openai-finish-to-stop finish)
              (sse-decoder-done decoder) t)))))

(defun sse-feed (decoder chunk &key coalesce (emit-tool-input t))
  "Feed raw HTTP SSE text CHUNK into DECODER; return list of delta plists.
When COALESCE is non-nil, adjacent `:text' or `:thinking' deltas within this
feed call are combined.  When EMIT-TOOL-INPUT is non-nil, at most one
`:tool-input' delta per modified tool block is emitted per `sse-feed' call."
  (check-type chunk string)
  (sse-record-raw decoder chunk)
  (let ((events-out '())
        (dirty-tools '()))
    (labels ((emit-delta (delta) (push delta events-out))
             (mark-dirty (block)
               (when emit-tool-input
                 (pushnew block dirty-tools :test #'eq))))
      (handler-case
          (multiple-value-bind (events rest)
              (sse-split-events (concatenate 'string (sse-decoder-pending decoder) chunk))
            (setf (sse-decoder-pending decoder) rest)
            (dolist (data events)
              (cond ((and (eq (sse-decoder-dialect decoder) :openai)
                          (string= (sse-string-trim data) "[DONE]"))
                     (setf (sse-decoder-done decoder) t))
                    (t
                     (let ((parsed (lispm-kernel/json:parse-json data :preserve-literals t)))
                       (ecase (sse-decoder-dialect decoder)
                         (:anthropic (sse-apply-anthropic-event decoder parsed #'emit-delta #'mark-dirty))
                         (:openai (sse-apply-openai-chunk decoder parsed #'emit-delta #'mark-dirty))))))))
        (serious-condition (condition)
          (unless (sse-decoder-client-error decoder)
            (setf (sse-decoder-client-error decoder)
                  (list :type "client_error" :message (condition-text condition)))))))
    (dolist (block (nreverse dirty-tools))
      (push (list :delta :tool-input
                  (list :id (or (sse-block-id block) "")
                        :name (or (sse-block-name block) "")
                        :json (sse-join-chunks (sse-block-json-chunks block))))
            events-out))
    (let ((ordered (nreverse events-out)))
      (if coalesce (sse-coalesce-deltas ordered) ordered))))

;;;; Finalizing to canonical Messages-shape wire plist

(defun sse-after-fallback-blocks (blocks)
  "Apply Anthropic `fallback' boundary stripping to plist block list BLOCKS."
  (let ((cut (position "fallback" blocks
                       :from-end t
                       :key (lambda (b) (getf b :type-raw))
                       :test #'string=)))
    (if (null cut)
        blocks
        (append (loop for b in (subseq blocks 0 cut)
                      when (eq (getf b :type) :text)
                        collect b)
                (nthcdr cut blocks)))))

(defun sse-canonical-block (decoder block &optional validate-json-p)
  "Convert `sse-block' BLOCK to a wire-safe plist; record invalid tool IDs."
  (let ((btype (sse-block-type block)))
    (cond
      ((string= btype "text")
       (list :type :text :type-raw "text"
             :text (sse-join-chunks (sse-block-text-chunks block))))
      ((string= btype "thinking")
       (let ((sig (sse-join-chunks (sse-block-signature-chunks block))))
         (append (list :type :thinking :type-raw "thinking"
                       :thinking (sse-join-chunks (sse-block-thinking-chunks block)))
                 (when (plusp (length sig)) (list :signature sig))
                 (when (sse-block-ephemeral block) (list :ephemeral t)))))
      ((string= btype "tool_use")
       (let* ((id (or (sse-block-id block)
                      (prog1 (format nil "call_k~D" (sse-decoder-next-synthetic-id decoder))
                        (incf (sse-decoder-next-synthetic-id decoder)))))
              (raw-json (sse-string-trim (sse-join-chunks (sse-block-json-chunks block))))
              (json-str (if (plusp (length raw-json))
                            raw-json
                            (or (sse-block-fallback-json block) "{}"))))
         (when (and validate-json-p
                    (plusp (length json-str))
                    (not (sse-valid-json-string-p json-str)))
           (pushnew id (sse-decoder-invalid decoder) :test #'string=)
           (setf json-str "{}"))
         (list :type :tool-use :type-raw "tool_use"
               :id id
               :name (or (sse-block-name block) "")
               :input-json json-str)))
      (t
       (append (list :type :other :type-raw btype
                     :text (sse-join-chunks (sse-block-text-chunks block)))
               (when (sse-block-raw-json block)
                 (list :json (sse-block-raw-json block))))))))

(defun sse-strip-internal-block-keys (block)
  "Return BLOCK plist without internal helper keys like `:type-raw'."
  (loop for (k v) on block by #'cddr
        unless (eq k :type-raw)
          append (list k v)))

(defun sse-complete-p (decoder)
  "Return true when DECODER saw a complete streamed response."
  (or (sse-decoder-done decoder)
      (and (eq (sse-decoder-dialect decoder) :openai)
           (not (null (sse-decoder-stop-reason decoder))))))

(defun sse-decode-whole-anthropic (decoder json)
  "Build canonical result plist from non-streamed Anthropic response JSON."
  (when (equal (lispm-kernel/json:json-get json "type") "message")
    (let* ((raw-list (sse-json-list (lispm-kernel/json:json-get json "content")))
           (blocks
             (loop for cb in raw-list
                   for btype = (or (sse-nonempty-string (lispm-kernel/json:json-get cb "type")) "")
                   collect
                   (cond
                     ((string= btype "text")
                      (list :type :text :type-raw "text"
                            :text (or (sse-nonempty-string (lispm-kernel/json:json-get cb "text")) "")))
                     ((string= btype "thinking")
                      (let ((sig (sse-nonempty-string (lispm-kernel/json:json-get cb "signature"))))
                        (append (list :type :thinking :type-raw "thinking"
                                      :thinking (or (sse-nonempty-string
                                                     (lispm-kernel/json:json-get cb "thinking"))
                                                    ""))
                                (when sig (list :signature sig)))))
                     ((string= btype "tool_use")
                      (let ((inp (lispm-kernel/json:json-get cb "input")))
                        (list :type :tool-use :type-raw "tool_use"
                              :id (or (sse-nonempty-string (lispm-kernel/json:json-get cb "id")) "")
                              :name (or (sse-nonempty-string (lispm-kernel/json:json-get cb "name")) "")
                              :input-json (if (sse-json-present-p inp)
                                              (lispm-kernel/json:encode-json inp)
                                              "{}"))))
                     (t
                      (list :type :other :type-raw btype
                            :json (lispm-kernel/json:encode-json cb))))))
           (filtered (mapcar #'sse-strip-internal-block-keys (sse-after-fallback-blocks blocks)))
           (usage (sse-merge-anthropic-usage nil (lispm-kernel/json:json-get json "usage"))))
      (list :ok t
            :status 200
            :id (sse-nonempty-string (lispm-kernel/json:json-get json "id"))
            :model (sse-nonempty-string (lispm-kernel/json:json-get json "model"))
            :stop-reason (or (sse-nonempty-string (lispm-kernel/json:json-get json "stop_reason")) "end_turn")
            :usage usage
            :invalid (reverse (sse-decoder-invalid decoder))
            :blocks filtered))))

(defun sse-decode-whole-openai (decoder json)
  "Build canonical result plist from non-streamed OpenAI response JSON."
  (declare (ignore decoder))
  (let ((choice-list (sse-json-list (lispm-kernel/json:json-get json "choices"))))
    (when (first choice-list)
      (let* ((choice (first choice-list))
             (message (lispm-kernel/json:json-get choice "message"))
             (reasoning (or (sse-nonempty-string (lispm-kernel/json:json-get message "reasoning_content"))
                            (sse-nonempty-string (lispm-kernel/json:json-get message "reasoning"))))
             (text (sse-nonempty-string (lispm-kernel/json:json-get message "content")))
             (call-list (sse-json-list (lispm-kernel/json:json-get message "tool_calls")))
             (finish (lispm-kernel/json:json-get choice "finish_reason"))
             (usage (sse-convert-openai-usage (lispm-kernel/json:json-get json "usage")))
             (blocks '())
             (invalid '())
             (n 0))
        (when reasoning
          (push (list :type :thinking :thinking reasoning :ephemeral t) blocks))
        (when text
          (push (list :type :text :text text) blocks))
        (dolist (call call-list)
          (let* ((fn (lispm-kernel/json:json-get call "function"))
                 (id (or (sse-nonempty-string (lispm-kernel/json:json-get call "id"))
                         (prog1 (format nil "call_w~D" n) (incf n))))
                 (name (or (sse-nonempty-string (lispm-kernel/json:json-get fn "name")) ""))
                 (raw-args (lispm-kernel/json:json-get fn "arguments"))
                 (arg-str (cond ((stringp raw-args) (sse-string-trim raw-args))
                                ((sse-json-present-p raw-args) (lispm-kernel/json:encode-json raw-args))
                                (t "{}"))))
            (when (and (plusp (length arg-str)) (not (sse-valid-json-string-p arg-str)))
              (push id invalid)
              (setf arg-str "{}"))
            (push (list :type :tool-use :id id :name name :input-json (if (plusp (length arg-str)) arg-str "{}"))
                  blocks)))
        (list :ok t
              :status 200
              :stop-reason (sse-openai-finish-to-stop (if (stringp finish) finish "stop"))
              :usage usage
              :invalid (nreverse invalid)
              :blocks (nreverse blocks))))))

(defun sse-extract-http-status-and-body (head-text tail-text)
  "Extract (values HTTP-STATUS BODY-TEXT) from raw curl output HEAD-TEXT and TAIL-TEXT."
  (flet ((last-marker-pos (text)
           (let ((pos 0) found)
             (loop for next = (search *http-status-marker* text :start2 pos)
                   while next
                   do (setf found next
                            pos (+ next (length *http-status-marker*))))
             found)))
    (let* ((marker-pos (last-marker-pos tail-text))
           (marker-len (length *http-status-marker*))
           (status (and marker-pos
                        (handler-case
                            (parse-integer (sse-string-trim (subseq tail-text (+ marker-pos marker-len))))
                          (parse-error () nil))))
           (head-marker (last-marker-pos head-text))
           (raw-body (if head-marker
                         (subseq head-text 0 head-marker)
                         head-text)))
      (values status (sse-string-trim raw-body)))))

(defun sse-finalize-stream-result (decoder)
  "Materialize DECODER's completed SSE blocks into canonical `:ok t' result plist."
  (let* ((table (sse-decoder-blocks decoder))
         (indices (sort (loop for k being the hash-keys of table collect k) #'<))
         (raw-blocks (loop for idx in indices
                           collect (sse-canonical-block decoder (gethash idx table) t)))
         (filtered (if (eq (sse-decoder-dialect decoder) :anthropic)
                       (sse-after-fallback-blocks raw-blocks)
                       raw-blocks))
         (blocks (mapcar #'sse-strip-internal-block-keys filtered))
         (usage (if (eq (sse-decoder-dialect decoder) :openai)
                    (sse-convert-openai-usage (sse-decoder-openai-usage decoder))
                    (sse-decoder-usage decoder))))
    (list :ok t
          :status 200
          :id (sse-decoder-message-id decoder)
          :model (sse-decoder-model decoder)
          :stop-reason (or (sse-decoder-stop-reason decoder) "end_turn")
          :usage usage
          :invalid (reverse (sse-decoder-invalid decoder))
          :blocks blocks)))

(defun sse-finish (decoder exit-plist)
  "Finalize DECODER with process EXIT-PLIST into canonical wire-safe result plist."
  (let* ((head-text (get-output-stream-string (sse-decoder-head decoder)))
         (tail-text (sse-decoder-tail decoder))
         (stderr (and (listp exit-plist) (getf exit-plist :stderr)))
         (err (or (sse-decoder-client-error decoder)
                  (sse-decoder-error decoder))))
    (multiple-value-bind (status body) (sse-extract-http-status-and-body head-text tail-text)
      (cond
        ((and (eql status 200)
              (not (sse-decoder-started decoder))
              (plusp (length body))
              (char= (char body 0) #\{))
         (let ((json (handler-case (lispm-kernel/json:parse-json body :preserve-literals t)
                       (lispm-kernel/json:json-error () nil))))
           (or (and (lispm-kernel/json:json-object-p json)
                    (ecase (sse-decoder-dialect decoder)
                      (:anthropic (sse-decode-whole-anthropic decoder json))
                      (:openai (sse-decode-whole-openai decoder json))))
               (let ((api-err (and (lispm-kernel/json:json-object-p json)
                                   (lispm-kernel/json:json-get json "error"))))
                 (if (sse-json-present-p api-err)
                     (sse-error-plist status api-err)
                     (list :ok nil :status status :type "bad_response"
                           :message (sse-truncate body 500)))))))
        ((and (eql status 200) err)
         (list :ok nil
               :status status
               :type (or (getf err :type) "api_error")
               :message (or (getf err :message) "API error")))
        ((and (eql status 200) (sse-complete-p decoder))
         (sse-finalize-stream-result decoder))
        ((eql status 200)
         (list :ok nil :status 200 :type "incomplete_stream"
               :message "The response stream ended early"))
        ((or (null status) (zerop status) (eql status 100))
         (list :ok nil
               :status (or status 0)
               :type "network_error"
               :message (cond ((plusp (length body)) (sse-truncate body 500))
                              ((and (stringp stderr) (plusp (length (sse-string-trim stderr))))
                               (sse-truncate (sse-string-trim stderr) 500))
                              ((stringp exit-plist) exit-plist)
                              (t "curl failed"))))
        (t
         (let* ((json (handler-case (lispm-kernel/json:parse-json body :preserve-literals t)
                        (lispm-kernel/json:json-error () nil)))
                (api-err (and (lispm-kernel/json:json-object-p json)
                              (lispm-kernel/json:json-get json "error"))))
           (sse-error-plist status (if (sse-json-present-p api-err)
                                       api-err
                                       (sse-truncate body 500)))))))))

;;;; `:llm-stream' reactor job (decoded off-thread SSE chunks + normalized outcome)

(define-job (llm-stream :class :reactor) (input)
  "Stream HTTP LLM request in `P_reactor', emitting decoded SSE deltas cleanly."
  (destructuring-bind (&key (dialect :anthropic) (coalesce t) &allow-other-keys) input
    (let* ((http-input (loop for (k v) on input by #'cddr
                             unless (member k '(:dialect :coalesce))
                               append (list k v)))
           (decoder (make-sse-decoder dialect)))
      (make-http-stream-spec
       http-input
       :chunk-transform (lambda (chunk)
                          (sse-feed decoder chunk :coalesce coalesce :emit-tool-input t))
       :finish-transform (lambda (status value)
                           (cond
                             ((eq status 'cancelled) (values 'cancelled nil nil))
                             ((eq status 'failed)
                              (values 'success
                                      (list :ok nil :status 0 :type "network_error"
                                            :message (if (stringp value) value "llm-stream failed"))
                                      nil))
                             (t
                              (values 'success (sse-finish decoder value) nil))))))))
