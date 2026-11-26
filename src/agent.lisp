;;;; agent.lisp --- Zero-mutex CSP agent control-plane actors and effect RPC

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

;;; CSP Agent Control Plane (`P_agents'):
;;;
;;;   Emacs ──(agent-start/turn/effect-reply/approval/viewport/resync/cancel)──▶ P_agents (mbox)
;;;     ▲                                                                          │
;;;     └──(turn-event / editor-effect-request / approval-request / snapshot)──────┤
;;;                                                                                ▼
;;;                                           P_scheduler (:http-stream / :exec / :search-files / :io)
;;;
;;; `P_agents' is a single sequential actor thread owning all per-session state
;;; tables without mutexes.  Each session tracks its turn FSM, viewport-aware
;;; delta coalescer, pending non-editor kernel sub-jobs, awaiting editor-only
;;; effect RPCs with timeouts, pending approvals, and bounded reconnect log.

(in-package #:lispm-kernel)

(defparameter *agent-visible-flush-ms* 16
  "Delta coalescing flush interval in milliseconds for `:visible' sessions.")

(defparameter *agent-hidden-flush-ms* 250
  "Delta coalescing flush interval in milliseconds for `:hidden' sessions.")

(defparameter *agent-visible-flush-bytes* 4096
  "Buffered delta size in characters triggering an immediate flush when `:visible'.")

(defparameter *agent-hidden-flush-bytes* 32768
  "Buffered delta size in characters triggering an immediate flush when `:hidden'.")

(defparameter *agent-effect-timeout* 30
  "Default seconds before an unanswered `editor-effect-request' times out.")

(defparameter *agent-max-events* 512
  "Maximum recent `turn-event' plists retained per session for `agent-resync'.")

(defparameter *agent-default-editor-tools*
  '("read_buffer" "list_buffers" "edit_buffer" "edit_file" "write_file" "eval_elisp")
  "Tools routed to Emacs over `editor-effect-request' by default.")

(defparameter *agent-default-kernel-tools*
  '("run_shell" "search_files" "workspace_cmd" "read_file")
  "Tools executed directly by `lispm-kernel' pools by default.")

;;;; Bounded local read-file job on `:io' pool

(define-job (read-file-range :class :io) (input)
  "Read bounded local file content from `:path' on an `:io' worker."
  (destructuring-bind (&key path (max-bytes 262144)) input
    (check-type path string)
    (check-type max-bytes (integer 1 4194304))
    (checkpoint)
    (with-open-file (stream (sb-ext:parse-native-namestring path)
                            :direction :input
                            :element-type '(unsigned-byte 8))
      (let* ((size (file-length stream))
             (to-read (min size max-bytes))
             (buf (make-array to-read :element-type '(unsigned-byte 8)))
             (got (read-sequence buf stream)))
        (checkpoint)
        (let ((text (sb-ext:octets-to-string buf :end got :external-format :utf-8)))
          (list :path path :size size :truncated (> size to-read) :content text))))))

;;;; Single-owner actor data structures

(defstruct (agent-effect (:constructor make-agent-effect (id call-id kind tool deadline))
                         (:copier nil))
  "One outstanding Kernel -> Emacs `editor-effect-request'."
  (id 0 :type integer :read-only t)
  (call-id "" :type string :read-only t)
  (kind :tool :type keyword :read-only t)
  (tool "" :type string :read-only t)
  (deadline 0 :type integer :read-only t))

(defstruct (agent-call (:constructor make-agent-call (id name input-json host approval))
                       (:copier nil))
  "One `tool_use' call tracked within an actor's current step."
  (id "" :type string :read-only t)
  (name "" :type string :read-only t)
  (input-json "{}" :type string :read-only t)
  (host :kernel :type (member :kernel :editor))
  (approval :auto :type (member :auto :ask :deny))
  (status :pending :type (member :pending :running :awaiting-approval :awaiting-effect :done))
  (job-id nil :type (or null integer))
  (effect-id nil :type (or null integer))
  (reasons '() :type list)
  (chunks '() :type list)
  (result nil :type (or null string))
  (is-error nil :type boolean))

(defstruct (agent-actor (:constructor %make-agent-actor (session owner-id))
                        (:copier nil))
  "Single-owner CSP state machine for one agent session."
  (session "" :type string :read-only t)
  (owner-id -1 :type integer :read-only t)
  (state :idle :type (member :idle :streaming :acting :awaiting-approval :awaiting-effect))
  (dialect :anthropic :type (member :anthropic :openai))
  (url "" :type string)
  (headers '() :type list)
  (root "." :type string)
  (env '() :type list)
  (curl "curl" :type string)
  (max-steps 16 :type integer)
  (auto-continue t :type boolean)
  (effect-timeout nil :type (or null real))
  (tool-policies '() :type list)
  (viewport :visible :type (member :visible :hidden))
  ;; Active turn state
  (turn-seq 0 :type integer)
  (turn-id nil :type (or null string))
  (step 0 :type integer)
  (turn-url nil :type (or null string))
  (turn-headers nil :type list)
  (turn-max-steps 16 :type integer)
  (turn-auto-continue t :type boolean)
  (body-json nil :type (or null string))
  (stream-job-id nil :type (or null integer))
  (decoder nil)
  (stream-text-chunks '() :type list)
  (stream-thinking-chunks '() :type list)
  (stream-tools '() :type list)
  (last-blocks '() :type list)
  (active-jobs (make-hash-table :test 'eql) :read-only t)
  (calls '() :type list)
  (calls-by-id (make-hash-table :test 'equal) :read-only t)
  (effects-by-id (make-hash-table :test 'eql) :read-only t)
  ;; Delta coalescer state
  (coal-kind nil :type (or null keyword))
  (coal-chunks '() :type list)
  (coal-bytes 0 :type fixnum)
  (coal-deadline nil :type (or null integer))
  ;; Reconnect & observability state
  (event-seq 0 :type integer)
  (events '() :type list)
  (completed-tools '() :type list)
  (completed-turns '() :type list))

(defstruct (agent-manager (:constructor %make-agent-manager (kernel inbox))
                          (:copier nil))
  "Single-owner coordinator running on the `P_agents' thread."
  (kernel nil :type kernel :read-only t)
  (inbox nil :type mbox :read-only t)
  (actors (make-hash-table :test 'equal) :read-only t)
  (next-req-id -1 :type integer)
  (next-owner-id -1 :type integer)
  (next-effect-id 1 :type integer)
  (stopping nil :type boolean))

;;;; Pure helpers & wire emission

(defun agent-now ()
  "Current monotonic timestamp in SBCL internal time units."
  (get-internal-real-time))

(defun agent-deadline-ms (ms)
  "Convert MS milliseconds from now into an internal-time-units deadline."
  (+ (agent-now) (ceiling (* ms internal-time-units-per-second) 1000)))

(defun agent-deadline-sec (sec)
  "Convert SEC seconds from now into an internal-time-units deadline."
  (+ (agent-now) (max 1 (round (* sec internal-time-units-per-second)))))

(defun agent-wire-emit (mgr form)
  "Send wire FORM asynchronously via `P_writer' without blocking `P_agents'."
  (credit-sink-put-control (kernel-outbox (agent-manager-kernel mgr))
                           (message-string form)))

(defun agent-emit-turn-event (mgr actor event-plist)
  "Assign sequence number to EVENT-PLIST, log on ACTOR, and emit `(turn-event ...)'."
  (let* ((seq (incf (agent-actor-event-seq actor)))
         (full (list* :seq seq event-plist))
         (events (cons full (agent-actor-events actor))))
    (when (> (length events) *agent-max-events*)
      (setf (cdr (nthcdr (1- *agent-max-events*) events)) nil))
    (setf (agent-actor-events actor) events)
    (agent-wire-emit mgr (list 'turn-event (agent-actor-session actor) full))
    full))

(defun agent-append-limited (list item limit)
  "Prepend ITEM to LIST keeping at most LIMIT most-recent items."
  (let ((next (cons item list)))
    (when (> (length next) limit)
      (setf (cdr (nthcdr (1- limit) next)) nil))
    next))

(defun agent-coerce-list (seq)
  "Return proper list elements from proper list or vector SEQ."
  (cond ((listp seq) seq)
        ((vectorp seq) (coerce seq 'list))
        (t '())))

(defun agent-plist-member-p (plist key)
  "Return true when KEY is explicitly present in PLIST."
  (loop for k in plist by #'cddr
        when (eq k key)
          do (return t)))

(defun agent-apply-config (actor config)
  "Apply configuration plist CONFIG onto ACTOR."
  (when (getf config :dialect)
    (setf (agent-actor-dialect actor) (getf config :dialect)))
  (when (getf config :url)
    (setf (agent-actor-url actor) (getf config :url)))
  (when (agent-plist-member-p config :headers)
    (setf (agent-actor-headers actor) (agent-coerce-list (getf config :headers))))
  (when (getf config :root)
    (setf (agent-actor-root actor) (getf config :root)))
  (when (agent-plist-member-p config :env)
    (setf (agent-actor-env actor) (agent-coerce-list (getf config :env))))
  (when (getf config :curl)
    (setf (agent-actor-curl actor) (getf config :curl)))
  (when (integerp (getf config :max-steps))
    (setf (agent-actor-max-steps actor) (max 1 (getf config :max-steps))))
  (when (agent-plist-member-p config :auto-continue)
    (setf (agent-actor-auto-continue actor) (and (getf config :auto-continue) t)))
  (when (realp (getf config :effect-timeout))
    (setf (agent-actor-effect-timeout actor) (max 0.01 (getf config :effect-timeout))))
  (when (agent-plist-member-p config :tool-policies)
    (setf (agent-actor-tool-policies actor) (getf config :tool-policies)))
  (when (member (getf config :viewport) '(:visible :hidden))
    (setf (agent-actor-viewport actor) (getf config :viewport))))

(defun agent-ensure-actor (mgr session &optional config)
  "Look up or create SESSION's actor in MGR and optionally apply CONFIG."
  (let ((actor (gethash session (agent-manager-actors mgr))))
    (unless actor
      (let ((owner (agent-manager-next-owner-id mgr)))
        (decf (agent-manager-next-owner-id mgr))
        (setf actor (%make-agent-actor session owner)
              (gethash session (agent-manager-actors mgr)) actor)))
    (when config
      (agent-apply-config actor config))
    actor))

;;;; Tool policy classification & effect kind mapping

(defun agent-classify-tool (actor name)
  "Return (values HOST APPROVAL REASONS) for tool NAME under ACTOR's policies."
  (let* ((policies (agent-actor-tool-policies actor))
         (plist-p (and (listp policies) (keywordp (first policies))))
         (override (and (listp policies) (not plist-p)
                        (assoc name policies :test #'equal)))
         (host (cond ((and override (member (getf (cdr override) :host) '(:kernel :editor)))
                      (getf (cdr override) :host))
                     ((and plist-p (member name (getf policies :editor) :test #'string=))
                      :editor)
                     ((and plist-p (member name (getf policies :kernel) :test #'string=))
                      :kernel)
                     ((member name *agent-default-editor-tools* :test #'string=)
                      :editor)
                     ((member name *agent-default-kernel-tools* :test #'string=)
                      :kernel)
                     (t :editor)))
         (approval (cond ((and override (member (getf (cdr override) :approval) '(:auto :ask :deny)))
                          (getf (cdr override) :approval))
                         ((and plist-p (member name (getf policies :deny) :test #'string=))
                          :deny)
                         ((and plist-p (member name (getf policies :ask) :test #'string=))
                          :ask)
                         (t :auto)))
         (reasons (or (and override (agent-coerce-list (getf (cdr override) :reasons)))
                      (and (eq approval :ask)
                           (list (format nil "Tool ~A requires approval" name))))))
    (values host approval reasons)))

(defun agent-effect-kind-for-tool (tool-name)
  "Map Emacs-side tool name string TOOL-NAME to a typed effect kind keyword."
  (cond ((string= tool-name "read_buffer") :read-buffer)
        ((string= tool-name "list_buffers") :list-buffers)
        ((string= tool-name "edit_buffer") :edit-buffer)
        ((string= tool-name "eval_elisp") :eval-elisp)
        (t :tool)))

;;;; Delta coalescing

(defun agent-coalescer-clear (actor)
  "Discard any un-flushed buffered deltas on ACTOR."
  (setf (agent-actor-coal-kind actor) nil
        (agent-actor-coal-chunks actor) '()
        (agent-actor-coal-bytes actor) 0
        (agent-actor-coal-deadline actor) nil))

(defun agent-coalescer-flush (mgr actor)
  "Flush ACTOR's buffered delta chunks into one wire `turn-event', if non-empty."
  (let ((kind (agent-actor-coal-kind actor))
        (chunks (agent-actor-coal-chunks actor)))
    (when (and kind chunks)
      (let ((text (sse-join-chunks chunks)))
        (agent-coalescer-clear actor)
        (when (plusp (length text))
          (agent-emit-turn-event mgr actor
                                 (list :turn-id (agent-actor-turn-id actor)
                                       :step (agent-actor-step actor)
                                       :type :delta
                                       :kind kind
                                       :text text)))))))

(defun agent-coalescer-push (mgr actor kind text)
  "Buffer delta TEXT of KIND (`:text' or `:thinking'), flushing by threshold/viewport."
  (when (and (stringp text) (plusp (length text)))
    (ecase kind
      (:text (push text (agent-actor-stream-text-chunks actor)))
      (:thinking (push text (agent-actor-stream-thinking-chunks actor))))
    (when (and (agent-actor-coal-kind actor)
               (not (eq (agent-actor-coal-kind actor) kind)))
      (agent-coalescer-flush mgr actor))
    (setf (agent-actor-coal-kind actor) kind)
    (push text (agent-actor-coal-chunks actor))
    (incf (agent-actor-coal-bytes actor) (length text))
    (unless (agent-actor-coal-deadline actor)
      (let ((ms (if (eq (agent-actor-viewport actor) :hidden)
                    *agent-hidden-flush-ms*
                    *agent-visible-flush-ms*)))
        (setf (agent-actor-coal-deadline actor) (agent-deadline-ms ms))))
    (let ((limit (if (eq (agent-actor-viewport actor) :hidden)
                     *agent-hidden-flush-bytes*
                     *agent-visible-flush-bytes*)))
      (when (>= (agent-actor-coal-bytes actor) limit)
        (agent-coalescer-flush mgr actor)))))

;;;; Submitting & cancelling internal scheduler jobs

(defun agent-submit-job (mgr actor job-name input &key on-chunk on-done)
  "Submit internal JOB-NAME to `P_scheduler' on behalf of ACTOR; return ID."
  (let ((req-id (agent-manager-next-req-id mgr))
        (inbox (agent-manager-inbox mgr))
        (session (agent-actor-session actor)))
    (decf (agent-manager-next-req-id mgr))
    (setf (gethash req-id (agent-actor-active-jobs actor))
          (cons on-chunk on-done))
    (post-control
     (agent-manager-kernel mgr)
     (list :submit-internal req-id job-name input
           (agent-actor-owner-id actor) 0 0
           (when on-chunk
             (lambda (chunk)
               (mbox-send inbox (list :job-chunk session req-id chunk))))
           (lambda (status value)
             (mbox-send inbox (list :job-done session req-id status value)))))
    req-id))

(defun agent-cancel-all-jobs (mgr actor)
  "Cancel all active scheduler requests owned by ACTOR."
  (let ((ids (loop for id being the hash-keys of (agent-actor-active-jobs actor)
                   collect id)))
    (clrhash (agent-actor-active-jobs actor))
    (dolist (id ids)
      (post-control (agent-manager-kernel mgr) (list :cancel id)))
    (setf (agent-actor-stream-job-id actor) nil)))

;;;; Building next step JSON bodies (lossless round-trip)

(defun agent-blocks-to-anthropic-content (blocks)
  "Convert canonical BLOCKS plists into Anthropic assistant JSON block vector."
  (coerce
   (loop for b in blocks
         for btype = (getf b :type)
         collect
         (cond
           ((eq btype :text)
            (lispm-kernel/json:make-json-object
             (list (cons "type" "text")
                   (cons "text" (or (getf b :text) "")))))
           ((eq btype :thinking)
            (let ((pairs (list (cons "type" "thinking")
                               (cons "thinking" (or (getf b :thinking) "")))))
              (when (getf b :signature)
                (setf pairs (nconc pairs (list (cons "signature" (getf b :signature))))))
              (lispm-kernel/json:make-json-object pairs)))
           ((eq btype :tool-use)
            (let* ((json-str (or (getf b :input-json) "{}"))
                   (parsed (handler-case
                               (lispm-kernel/json:parse-json json-str :preserve-literals t)
                             (lispm-kernel/json:json-error ()
                               (lispm-kernel/json:make-json-object '())))))
              (lispm-kernel/json:make-json-object
               (list (cons "type" "tool_use")
                     (cons "id" (or (getf b :id) ""))
                     (cons "name" (or (getf b :name) ""))
                     (cons "input" parsed)))))
           (t
            (lispm-kernel/json:make-json-object
             (list (cons "type" "text")
                   (cons "text" (or (getf b :text) "")))))))
   'simple-vector))

(defun agent-calls-to-anthropic-results (calls)
  "Convert finished AGENT-CALL structs into Anthropic tool_result user block vector."
  (coerce
   (loop for call in calls
         collect (lispm-kernel/json:make-json-object
                  (append (list (cons "type" "tool_result")
                                (cons "tool_use_id" (agent-call-id call))
                                (cons "content" (or (agent-call-result call) "")))
                          (when (agent-call-is-error call)
                            (list (cons "is_error" t))))))
   'simple-vector))

(defun agent-calls-to-openai-tool-calls (blocks)
  "Extract OpenAI `tool_calls' vector from canonical BLOCKS."
  (coerce
   (loop for b in blocks
         when (eq (getf b :type) :tool-use)
           collect (lispm-kernel/json:make-json-object
                    (list (cons "id" (or (getf b :id) ""))
                          (cons "type" "function")
                          (cons "function"
                                (lispm-kernel/json:make-json-object
                                 (list (cons "name" (or (getf b :name) ""))
                                       (cons "arguments" (or (getf b :input-json) "{}"))))))))
   'simple-vector))

(defun agent-append-next-turn-body (dialect body-json blocks calls)
  "Append BLOCKS assistant turn and CALLS tool results to BODY-JSON for next step."
  (let* ((doc (lispm-kernel/json:parse-json body-json :preserve-literals t))
         (pairs (lispm-kernel/json:json-object-pairs doc))
         (messages-pair (assoc "messages" pairs :test #'string=))
         (old-msgs (if messages-pair
                       (agent-coerce-list (cdr messages-pair))
                       '()))
         (new-msgs
           (ecase dialect
             (:anthropic
              (list
               (lispm-kernel/json:make-json-object
                (list (cons "role" "assistant")
                      (cons "content" (agent-blocks-to-anthropic-content blocks))))
               (lispm-kernel/json:make-json-object
                (list (cons "role" "user")
                      (cons "content" (agent-calls-to-anthropic-results calls))))))
             (:openai
              (let* ((text-parts (loop for b in blocks
                                       when (eq (getf b :type) :text)
                                         collect (or (getf b :text) "")))
                     (joined-text (if text-parts
                                      (apply #'concatenate 'string text-parts)
                                      :null))
                     (tool-calls (agent-calls-to-openai-tool-calls blocks))
                     (assistant-pairs
                       (append (list (cons "role" "assistant")
                                     (cons "content" joined-text))
                               (when (plusp (length tool-calls))
                                 (list (cons "tool_calls" tool-calls)))))
                     (tool-msgs
                       (loop for call in calls
                             collect (lispm-kernel/json:make-json-object
                                      (list (cons "role" "tool")
                                            (cons "tool_call_id" (agent-call-id call))
                                            (cons "content" (or (agent-call-result call) "")))))))
                (cons (lispm-kernel/json:make-json-object assistant-pairs) tool-msgs)))))
         (updated-vec (coerce (append old-msgs new-msgs) 'simple-vector))
         (updated-pairs (loop for pair in pairs
                              collect (if (string= (car pair) "messages")
                                          (cons "messages" updated-vec)
                                          pair))))
    (unless messages-pair
      (setf updated-pairs (append updated-pairs (list (cons "messages" updated-vec)))))
    (lispm-kernel/json:encode-json (lispm-kernel/json:make-json-object updated-pairs))))

;;;; Step launch & tool execution

(defun agent-start-http-step (mgr actor)
  "Launch the current step's `:http-stream' job for ACTOR cleanly."
  (setf (agent-actor-state actor) :streaming
        (agent-actor-decoder actor) (make-sse-decoder (agent-actor-dialect actor))
        (agent-actor-stream-text-chunks actor) '()
        (agent-actor-stream-thinking-chunks actor) '()
        (agent-actor-stream-tools actor) '())
  (agent-coalescer-clear actor)
  (let* ((turn-id (agent-actor-turn-id actor))
         (step (agent-actor-step actor))
         (input (list :url (or (agent-actor-turn-url actor) (agent-actor-url actor))
                      :headers (or (agent-actor-turn-headers actor) (agent-actor-headers actor))
                      :body (or (agent-actor-body-json actor) "{}")
                      :curl (agent-actor-curl actor)
                      :env (agent-actor-env actor)))
         (job-id nil))
    (setf job-id
          (agent-submit-job
           mgr actor :http-stream input
           :on-chunk (lambda (chunk)
                       (when (and (eql job-id (agent-actor-stream-job-id actor))
                                  (eq (agent-actor-state actor) :streaming))
                         (dolist (delta (sse-feed (agent-actor-decoder actor) chunk :coalesce t))
                           (let ((kind (second delta))
                                 (payload (third delta)))
                             (case kind
                               ((:text :thinking)
                                (agent-coalescer-push mgr actor kind payload))
                               (:tool
                                (agent-coalescer-flush mgr actor)
                                (push payload (agent-actor-stream-tools actor))
                                (agent-emit-turn-event
                                 mgr actor (list :turn-id turn-id :step step
                                                 :type :delta :kind :tool :text payload))))))))
           :on-done (lambda (status value)
                      (when (eql job-id (agent-actor-stream-job-id actor))
                        (setf (agent-actor-stream-job-id actor) nil)
                        (agent-handle-http-done mgr actor status value)))))
    (setf (agent-actor-stream-job-id actor) job-id)))

(defun agent-settle-call (mgr actor call result-str is-error)
  "Record outcome of CALL on ACTOR, emit `:tool-result', and advance turn if done."
  (setf (agent-call-status call) :done
        (agent-call-result call) result-str
        (agent-call-is-error call) (and is-error t))
  (let ((summary (list :turn-id (agent-actor-turn-id actor)
                       :step (agent-actor-step actor)
                       :call-id (agent-call-id call)
                       :tool (agent-call-name call)
                       :host (agent-call-host call)
                       :is-error (and is-error t)
                       :result result-str)))
    (setf (agent-actor-completed-tools actor)
          (agent-append-limited (agent-actor-completed-tools actor) summary 64))
    (agent-emit-turn-event mgr actor (list* :type :tool-result summary)))
  (agent-maybe-finish-wave mgr actor))

(defun agent-parse-call-input (call)
  "Parse CALL's `:input-json' into a JSON object (empty object on empty)."
  (handler-case
      (lispm-kernel/json:parse-json (agent-call-input-json call) :preserve-literals t)
    (lispm-kernel/json:json-error ()
      (lispm-kernel/json:make-json-object '()))))

(defun agent-format-exec-result (status value chunks)
  "Format `:exec' settlement into (values TEXT IS-ERROR-P)."
  (let ((output (sse-join-chunks chunks)))
    (cond
      ((eq status 'success)
       (let ((code (getf value :exit))
             (sig (getf value :signal))
             (err (or (getf value :stderr) "")))
         (cond
           ((and (eql code 0) (string= err "")) (values output nil))
           ((eql code 0)
            (values (format nil "~A~@[~&[stderr] ~A~]" output (sse-nonempty-string err)) nil))
           (sig
            (values (format nil "Process ended by signal ~D~%~A~@[~&~A~]"
                            sig output (sse-nonempty-string err))
                    t))
           (t
            (values (format nil "Exit ~D~%~A~@[~&~A~]"
                            code output (sse-nonempty-string err))
                    t)))))
      (t
       (values (format nil "Exec ~(~A~): ~A~@[~%~A~]" status (or value "") (sse-nonempty-string output))
               t)))))

(defun agent-format-search-result (status value)
  "Format `:search-files' settlement into (values TEXT IS-ERROR-P)."
  (if (not (eq status 'success))
      (values (format nil "Search ~(~A~): ~A" status (or value "")) t)
      (let* ((items (getf value :items))
             (lines '()))
        (dolist (item items)
          (let ((file (getf item :file))
                (matches (getf item :matches)))
            (dolist (m matches)
              (push (format nil "~A:~D:~A" file (first m) (second m)) lines))))
        (values (if lines
                    (format nil "~{~A~^~%~}" (nreverse lines))
                    "No matches.")
                nil))))

(defun agent-dispatch-kernel-tool (mgr actor call)
  "Execute kernel-hosted CALL via `P_scheduler' without blocking Emacs."
  (let* ((name (agent-call-name call))
         (obj (agent-parse-call-input call))
         (root (agent-actor-root actor)))
    (setf (agent-call-status call) :running)
    (cond
      ((string= name "run_shell")
       (let* ((cmd (or (lispm-kernel/json:json-get obj "command") ""))
              (dir (or (sse-nonempty-string (lispm-kernel/json:json-get obj "directory")) root))
              (timeout (or (sse-json-integer (lispm-kernel/json:json-get obj "timeout")) 60)))
         (setf (agent-call-job-id call)
               (agent-submit-job
                mgr actor :exec
                (list :program "/bin/sh"
                      :args (list "-c" cmd)
                      :cwd dir
                      :env (agent-actor-env actor)
                      :env-inherit t
                      :timeout timeout
                      :combine-error t)
                :on-chunk (lambda (chunk)
                            (when (eq (agent-call-status call) :running)
                              (push chunk (agent-call-chunks call))))
                :on-done (lambda (status value)
                           (when (eq (agent-call-status call) :running)
                             (multiple-value-bind (text err-p)
                                 (agent-format-exec-result status value (agent-call-chunks call))
                               (agent-settle-call mgr actor call text err-p))))))))
      ((string= name "workspace_cmd")
       (let* ((program (or (sse-nonempty-string (lispm-kernel/json:json-get obj "program")) "git"))
              (args-raw (agent-coerce-list (lispm-kernel/json:json-get obj "args")))
              (args (loop for a in args-raw collect (if (stringp a) a (princ-to-string a))))
              (dir (or (sse-nonempty-string (lispm-kernel/json:json-get obj "directory")) root))
              (timeout (or (sse-json-integer (lispm-kernel/json:json-get obj "timeout")) 60)))
         (setf (agent-call-job-id call)
               (agent-submit-job
                mgr actor :exec
                (list :program program
                      :args args
                      :cwd dir
                      :env (agent-actor-env actor)
                      :env-inherit t
                      :search (not (and (plusp (length program)) (char= (char program 0) #\/)))
                      :timeout timeout
                      :combine-error t)
                :on-chunk (lambda (chunk)
                            (when (eq (agent-call-status call) :running)
                              (push chunk (agent-call-chunks call))))
                :on-done (lambda (status value)
                           (when (eq (agent-call-status call) :running)
                             (multiple-value-bind (text err-p)
                                 (agent-format-exec-result status value (agent-call-chunks call))
                               (agent-settle-call mgr actor call text err-p))))))))
      ((string= name "search_files")
       (let* ((pattern (or (lispm-kernel/json:json-get obj "pattern") ""))
              (dir (or (sse-nonempty-string (lispm-kernel/json:json-get obj "directory")) root))
              (files-raw (agent-coerce-list (lispm-kernel/json:json-get obj "files")))
              (raw-entries (or (loop for f in files-raw when (stringp f) collect f) (list dir)))
              (files (loop for entry in raw-entries
                           for stamp = (lispm-kernel/files:file-stamp entry :follow t)
                           collect (if (and stamp (eq (lispm-kernel/files:stamp-kind stamp) :directory))
                                       (ensure-trailing-slash entry)
                                       entry)))
              (glob (sse-nonempty-string (lispm-kernel/json:json-get obj "glob")))
              (case-fold (eq (lispm-kernel/json:json-get obj "case_fold") t))
              (max-matches (or (sse-json-integer (lispm-kernel/json:json-get obj "max_matches")) 100)))
         (setf (agent-call-job-id call)
               (agent-submit-job
                mgr actor :search-files
                (list :files files
                      :pattern pattern
                      :case-fold case-fold
                      :glob glob
                      :max-matches max-matches)
                :on-done (lambda (status value)
                           (when (eq (agent-call-status call) :running)
                             (multiple-value-bind (text err-p)
                                 (agent-format-search-result status value)
                               (agent-settle-call mgr actor call text err-p))))))))
      ((string= name "read_file")
       (let* ((raw-path (or (lispm-kernel/json:json-get obj "path") ""))
              (path (if (and (plusp (length raw-path)) (char= (char raw-path 0) #\/))
                        raw-path
                        (concatenate 'string (string-right-trim "/" root) "/" raw-path))))
         (setf (agent-call-job-id call)
               (agent-submit-job
                mgr actor :read-file-range
                (list :path path :max-bytes 262144)
                :on-done (lambda (status value)
                           (when (eq (agent-call-status call) :running)
                             (if (eq status 'success)
                                 (agent-settle-call mgr actor call (or (getf value :content) "") nil)
                                 (agent-settle-call mgr actor call
                                                    (format nil "read_file ~(~A~): ~A" status (or value ""))
                                                    t))))))))
      (t
       (agent-dispatch-editor-effect mgr actor call)))))

(defun agent-dispatch-editor-effect (mgr actor call)
  "Emit typed `editor-effect-request' to Emacs and track deadline for CALL."
  (let* ((effect-id (agent-manager-next-effect-id mgr))
         (timeout (or (agent-actor-effect-timeout actor) *agent-effect-timeout*))
         (kind (agent-effect-kind-for-tool (agent-call-name call)))
         (eff (make-agent-effect effect-id
                                 (agent-call-id call)
                                 kind
                                 (agent-call-name call)
                                 (agent-deadline-sec timeout))))
    (incf (agent-manager-next-effect-id mgr))
    (setf (agent-call-status call) :awaiting-effect
          (agent-call-effect-id call) effect-id
          (gethash effect-id (agent-actor-effects-by-id actor)) eff)
    (agent-wire-emit
     mgr (list 'editor-effect-request
               (agent-actor-session actor)
               effect-id
               kind
               (list :call-id (agent-call-id call)
                     :tool (agent-call-name call)
                     :input-json (agent-call-input-json call))
               :timeout (max 1 (ceiling timeout))))))

(defun agent-dispatch-call (mgr actor call)
  "Dispatch approved CALL to either `:kernel' or `:editor'."
  (if (eq (agent-call-host call) :kernel)
      (agent-dispatch-kernel-tool mgr actor call)
      (agent-dispatch-editor-effect mgr actor call)))

(defun agent-refresh-acting-state (actor)
  "Update ACTOR's high-level FSM state from its remaining pending calls."
  (when (member (agent-actor-state actor) '(:acting :awaiting-approval :awaiting-effect))
    (setf (agent-actor-state actor)
          (cond ((some (lambda (c) (eq (agent-call-status c) :awaiting-approval))
                       (agent-actor-calls actor))
                 :awaiting-approval)
                ((some (lambda (c) (eq (agent-call-status c) :awaiting-effect))
                       (agent-actor-calls actor))
                 :awaiting-effect)
                (t :acting)))))

(defun agent-collect-text (blocks)
  "Concatenate `:text' blocks from BLOCKS into a single reply string."
  (apply #'concatenate 'string
         (loop for b in blocks
               when (eq (getf b :type) :text)
                 collect (or (getf b :text) ""))))

(defun agent-maybe-finish-wave (mgr actor)
  "If all CALLS in ACTOR's current step settled, continue to next step or finish."
  (when (and (agent-actor-turn-id actor)
             (every (lambda (c) (eq (agent-call-status c) :done))
                    (agent-actor-calls actor)))
    (let ((calls (agent-actor-calls actor))
          (blocks (agent-actor-last-blocks actor))
          (step (agent-actor-step actor))
          (turn-id (agent-actor-turn-id actor)))
      (setf (agent-actor-calls actor) '())
      (clrhash (agent-actor-calls-by-id actor))
      (clrhash (agent-actor-effects-by-id actor))
      (let ((results (loop for c in calls
                           collect (list :call-id (agent-call-id c)
                                         :tool (agent-call-name c)
                                         :is-error (agent-call-is-error c)
                                         :result (or (agent-call-result c) "")))))
        (cond
          ((not (agent-actor-turn-auto-continue actor))
           (let ((summary (list :turn-id turn-id :step step :status :done
                                :text (agent-collect-text blocks)
                                :tool-results results)))
             (setf (agent-actor-completed-turns actor)
                   (agent-append-limited (agent-actor-completed-turns actor) summary 32)
                   (agent-actor-state actor) :idle
                   (agent-actor-turn-id actor) nil)
             (agent-emit-turn-event mgr actor
                                    (list :turn-id turn-id :step step :type :turn-done
                                          :text (getf summary :text)
                                          :tool-results results))))
          ((>= step (agent-actor-turn-max-steps actor))
           (let ((summary (list :turn-id turn-id :step step :status :step-limit
                                :text (agent-collect-text blocks)
                                :tool-results results)))
             (setf (agent-actor-completed-turns actor)
                   (agent-append-limited (agent-actor-completed-turns actor) summary 32)
                   (agent-actor-state actor) :idle
                   (agent-actor-turn-id actor) nil)
             (agent-emit-turn-event mgr actor
                                    (list :turn-id turn-id :step step :type :step-limit
                                          :tool-results results))))
          (t
           (handler-case
               (let ((next-body (agent-append-next-turn-body
                                 (agent-actor-dialect actor)
                                 (or (agent-actor-body-json actor) "{}")
                                 blocks calls)))
                 (incf (agent-actor-step actor))
                 (setf (agent-actor-body-json actor) next-body)
                 (agent-start-http-step mgr actor))
             (serious-condition (condition)
               (setf (agent-actor-state actor) :idle
                     (agent-actor-turn-id actor) nil)
               (agent-emit-turn-event
                mgr actor (list :turn-id turn-id :step step :type :turn-error
                                :status 0 :error-type "body_build_error"
                                :message (condition-text condition))))))))))
  (agent-refresh-acting-state actor))

(defun agent-handle-http-done (mgr actor status value)
  "Handle completion of ACTOR's HTTP stream step and either finish or run tools."
  (agent-coalescer-flush mgr actor)
  (let ((turn-id (agent-actor-turn-id actor))
        (step (agent-actor-step actor)))
    (cond
      ((eq status 'cancelled)
       (setf (agent-actor-state actor) :idle
             (agent-actor-turn-id actor) nil))
      ((eq status 'failed)
       (let ((err (list :turn-id turn-id :step step :type :turn-error
                        :status 0 :error-type "network_error"
                        :message (if (stringp value) value "http-stream failed"))))
         (setf (agent-actor-completed-turns actor)
               (agent-append-limited (agent-actor-completed-turns actor)
                                     (list :turn-id turn-id :step step :status :error
                                           :message (getf err :message))
                                     32)
               (agent-actor-state actor) :idle
               (agent-actor-turn-id actor) nil)
         (agent-emit-turn-event mgr actor err)))
      (t
       (let ((res (sse-finish (agent-actor-decoder actor) value)))
         (if (not (getf res :ok))
             (let ((summary (list :turn-id turn-id :step step :status :error
                                  :error-type (getf res :type)
                                  :message (getf res :message))))
               (setf (agent-actor-completed-turns actor)
                     (agent-append-limited (agent-actor-completed-turns actor) summary 32)
                     (agent-actor-state actor) :idle
                     (agent-actor-turn-id actor) nil)
               (agent-emit-turn-event mgr actor
                                      (list :turn-id turn-id :step step :type :turn-error
                                            :status (getf res :status)
                                            :error-type (getf res :type)
                                            :message (getf res :message))))
             (let* ((blocks (getf res :blocks))
                    (stop-reason (or (getf res :stop-reason) "end_turn"))
                    (usage (getf res :usage))
                    (invalid (getf res :invalid))
                    (tool-blocks (loop for b in blocks
                                       when (eq (getf b :type) :tool-use)
                                         collect b))
                    (proceed (and tool-blocks
                                  (not (member stop-reason
                                               '("max_tokens" "refusal" "model_context_window_exceeded")
                                               :test #'string=)))))
               (setf (agent-actor-last-blocks actor) blocks)
               (agent-emit-turn-event mgr actor
                                      (list :turn-id turn-id :step step :type :step-response
                                            :stop-reason stop-reason :usage usage
                                            :invalid invalid :blocks blocks))
               (if (not proceed)
                   (let* ((reply (agent-collect-text blocks))
                          (summary (list :turn-id turn-id :step step :status :done
                                         :stop-reason stop-reason :usage usage :text reply)))
                     (setf (agent-actor-completed-turns actor)
                           (agent-append-limited (agent-actor-completed-turns actor) summary 32)
                           (agent-actor-state actor) :idle
                           (agent-actor-turn-id actor) nil)
                     (agent-emit-turn-event mgr actor
                                            (list :turn-id turn-id :step step :type :turn-done
                                                  :stop-reason stop-reason :usage usage :text reply)))
                   (agent-begin-tool-wave mgr actor tool-blocks invalid)))))))))

(defun agent-begin-tool-wave (mgr actor tool-blocks invalid)
  "Create, classify, and launch all tool calls in TOOL-BLOCKS for ACTOR."
  (setf (agent-actor-state actor) :acting
        (agent-actor-calls actor) '())
  (clrhash (agent-actor-calls-by-id actor))
  (clrhash (agent-actor-effects-by-id actor))
  (let ((calls '()))
    (dolist (b tool-blocks)
      (let* ((id (or (getf b :id) ""))
             (name (or (getf b :name) ""))
             (input-json (or (getf b :input-json) "{}")))
        (multiple-value-bind (host approval reasons) (agent-classify-tool actor name)
          (let ((call (make-agent-call id name input-json host approval)))
            (setf (agent-call-reasons call) reasons)
            (push call calls)
            (setf (gethash id (agent-actor-calls-by-id actor)) call)))))
    (setf calls (nreverse calls)
          (agent-actor-calls actor) calls)
    (dolist (call calls)
      (cond
        ((member (agent-call-id call) invalid :test #'string=)
         (agent-settle-call
          mgr actor call
          "INVALID_JSON: the input of this call was not valid JSON. Make the call again." t))
        ((eq (agent-call-approval call) :deny)
         (agent-settle-call mgr actor call "Tool call denied by policy." t))
        ((eq (agent-call-approval call) :ask)
         (setf (agent-call-status call) :awaiting-approval)
         (agent-wire-emit mgr (list 'approval-request
                                    (agent-actor-session actor)
                                    (agent-call-id call)
                                    (agent-call-name call)
                                    (agent-call-input-json call)
                                    (agent-call-reasons call))))
        (t
         (agent-dispatch-call mgr actor call))))
    (agent-refresh-acting-state actor)
    (agent-maybe-finish-wave mgr actor)))

;;;; Snapshot, resync, cancellation & command handlers

(defun agent-build-snapshot (mgr actor &optional since-seq)
  "Construct a complete reconnect/resync plist for ACTOR (flushing coalescer first)."
  (agent-coalescer-flush mgr actor)
  (let ((pending-effects '())
        (pending-approvals '())
        (recent-events (reverse (agent-actor-events actor))))
    (maphash (lambda (_id eff)
               (declare (ignore _id))
               (push (list :effect-id (agent-effect-id eff)
                           :call-id (agent-effect-call-id eff)
                           :kind (agent-effect-kind eff)
                           :tool (agent-effect-tool eff))
                     pending-effects))
             (agent-actor-effects-by-id actor))
    (dolist (call (agent-actor-calls actor))
      (when (eq (agent-call-status call) :awaiting-approval)
        (push (list :call-id (agent-call-id call)
                    :tool (agent-call-name call)
                    :input-json (agent-call-input-json call)
                    :reasons (agent-call-reasons call))
              pending-approvals)))
    (when (integerp since-seq)
      (setf recent-events (loop for ev in recent-events
                                when (> (getf ev :seq 0) since-seq)
                                  collect ev)))
    (list :session (agent-actor-session actor)
          :state (agent-actor-state actor)
          :dialect (agent-actor-dialect actor)
          :viewport (agent-actor-viewport actor)
          :turn-id (agent-actor-turn-id actor)
          :step (agent-actor-step actor)
          :event-seq (agent-actor-event-seq actor)
          :stream (list :text (sse-join-chunks (agent-actor-stream-text-chunks actor))
                        :thinking (sse-join-chunks (agent-actor-stream-thinking-chunks actor))
                        :tools (reverse (agent-actor-stream-tools actor)))
          :pending-effects (nreverse pending-effects)
          :pending-approvals (nreverse pending-approvals)
          :completed-tools (reverse (agent-actor-completed-tools actor))
          :completed-turns (reverse (agent-actor-completed-turns actor))
          :events recent-events)))

(defun agent-summary-list (mgr)
  "Return lightweight summary plists across all live actors in MGR."
  (let ((items '()))
    (maphash (lambda (_session actor)
               (declare (ignore _session))
               (push (list :session (agent-actor-session actor)
                           :state (agent-actor-state actor)
                           :turn-id (agent-actor-turn-id actor)
                           :step (agent-actor-step actor)
                           :viewport (agent-actor-viewport actor)
                           :event-seq (agent-actor-event-seq actor))
                     items))
             (agent-manager-actors mgr))
    (sort items #'string< :key (lambda (pl) (getf pl :session)))))

(defun agent-cmd-turn (mgr actor input)
  "Handle `(:agent-turn ...)' INPUT for ACTOR."
  (when (not (eq (agent-actor-state actor) :idle))
    (agent-cmd-cancel mgr actor "Superseded by new turn."))
  (incf (agent-actor-turn-seq actor))
  (let ((turn-id (or (and (getf input :turn-id) (princ-to-string (getf input :turn-id)))
                     (format nil "turn-~D" (agent-actor-turn-seq actor)))))
    (setf (agent-actor-turn-id actor) turn-id
          (agent-actor-step actor) 1
          (agent-actor-turn-url actor) (getf input :url)
          (agent-actor-turn-headers actor) (and (agent-plist-member-p input :headers)
                                                (agent-coerce-list (getf input :headers)))
          (agent-actor-turn-max-steps actor) (or (and (integerp (getf input :max-steps))
                                                      (max 1 (getf input :max-steps)))
                                                 (agent-actor-max-steps actor))
          (agent-actor-turn-auto-continue actor) (if (agent-plist-member-p input :auto-continue)
                                                     (and (getf input :auto-continue) t)
                                                     (agent-actor-auto-continue actor))
          (agent-actor-body-json actor) (or (getf input :body) "{}")
          (agent-actor-calls actor) '())
    (clrhash (agent-actor-calls-by-id actor))
    (clrhash (agent-actor-effects-by-id actor))
    (agent-emit-turn-event mgr actor (list :turn-id turn-id :step 1 :type :turn-started))
    (agent-start-http-step mgr actor)))

(defun agent-cmd-cancel (mgr actor &optional (reason "Cancelled by client."))
  "Cancel ACTOR's active turn, sub-jobs, effects, and approvals cleanly."
  (agent-coalescer-flush mgr actor)
  (agent-cancel-all-jobs mgr actor)
  (let ((turn-id (agent-actor-turn-id actor))
        (step (agent-actor-step actor)))
    (dolist (call (agent-actor-calls actor))
      (unless (eq (agent-call-status call) :done)
        (setf (agent-call-status call) :done
              (agent-call-result call) reason
              (agent-call-is-error call) t)))
    (setf (agent-actor-calls actor) '())
    (clrhash (agent-actor-calls-by-id actor))
    (clrhash (agent-actor-effects-by-id actor))
    (setf (agent-actor-state actor) :idle
          (agent-actor-turn-id actor) nil)
    (when turn-id
      (setf (agent-actor-completed-turns actor)
            (agent-append-limited (agent-actor-completed-turns actor)
                                  (list :turn-id turn-id :step step :status :cancelled :reason reason)
                                  32))
      (agent-emit-turn-event mgr actor
                             (list :turn-id turn-id :step step :type :turn-cancelled :reason reason)))))

(defun agent-handle-command (mgr cmd)
  "Dispatch one CSP control or sub-job message CMD inside `P_agents'."
  (case (first cmd)
    (:stop
     (setf (agent-manager-stopping mgr) t)
     (maphash (lambda (_session actor)
                (declare (ignore _session))
                (agent-cancel-all-jobs mgr actor)
                (agent-coalescer-clear actor)
                (clrhash (agent-actor-effects-by-id actor)))
              (agent-manager-actors mgr)))
    (:agent-start
     (destructuring-bind (session config) (rest cmd)
       (let ((actor (agent-ensure-actor mgr session config)))
         (agent-emit-turn-event mgr actor (list :type :session-ready :dialect (agent-actor-dialect actor))))))
    (:agent-turn
     (destructuring-bind (session input) (rest cmd)
       (let ((actor (agent-ensure-actor mgr session)))
         (agent-cmd-turn mgr actor input))))
    (:agent-cancel
     (let ((actor (gethash (second cmd) (agent-manager-actors mgr))))
       (when actor
         (agent-cmd-cancel mgr actor))))
    (:agent-stop
     (let* ((session (second cmd))
            (actor (gethash session (agent-manager-actors mgr))))
       (when actor
         (agent-cmd-cancel mgr actor "Session stopped.")
         (remhash session (agent-manager-actors mgr)))))
    (:agent-effect-reply
     (destructuring-bind (session effect-id status result) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr))))
         (when actor
           (let ((eff (gethash effect-id (agent-actor-effects-by-id actor))))
             (when eff
               (remhash effect-id (agent-actor-effects-by-id actor))
               (let ((call (gethash (agent-effect-call-id eff) (agent-actor-calls-by-id actor))))
                 (when (and call (eq (agent-call-status call) :awaiting-effect))
                   (let ((text (cond ((stringp result) result)
                                     ((null result) "")
                                     (t (princ-to-string result))))
                         (err-p (not (eq status :ok))))
                     (agent-settle-call mgr actor call text err-p))))))))))
    (:agent-approval-decision
     (destructuring-bind (session call-id decision reason) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr))))
         (when actor
           (let ((call (gethash call-id (agent-actor-calls-by-id actor))))
             (when (and call (eq (agent-call-status call) :awaiting-approval))
               (agent-emit-turn-event mgr actor
                                      (list :turn-id (agent-actor-turn-id actor)
                                            :step (agent-actor-step actor)
                                            :type :approval-settled
                                            :call-id call-id
                                            :decision decision
                                            :reason reason))
               (cond
                 ((member decision '(:approve :allow))
                  (agent-dispatch-call mgr actor call)
                  (agent-refresh-acting-state actor)
                  (agent-maybe-finish-wave mgr actor))
                 (t
                  (agent-settle-call
                   mgr actor call
                   (if (and (stringp reason) (plusp (length reason)))
                       (format nil "The user denied this call. Their reason: ~A" reason)
                       "The user denied this call. Do not repeat it unchanged; adapt, or ask the user.")
                   t)))))))))
    (:agent-viewport-subscribe
     (destructuring-bind (session mode) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr))))
         (when (and actor (member mode '(:visible :hidden)))
           (setf (agent-actor-viewport actor) mode)
           (when (eq mode :visible)
             (agent-coalescer-flush mgr actor))))))
    (:agent-resync
     (destructuring-bind (session since-seq) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr))))
         (agent-wire-emit
          mgr (list 'agent-snapshot session
                    (if actor
                        (agent-build-snapshot mgr actor since-seq)
                        (list :session session :state :missing :events '())))))))
    (:agent-resync-sync
     (destructuring-bind (session since-seq reply-mbox) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr))))
         (mbox-send reply-mbox
                    (if actor
                        (agent-build-snapshot mgr actor since-seq)
                        (list :session session :state :missing :events '()))))))
    (:agent-list
     (agent-wire-emit mgr (list 'agent-list (agent-summary-list mgr))))
    (:agent-list-sync
     (mbox-send (second cmd) (agent-summary-list mgr)))
    (:job-chunk
     (destructuring-bind (session req-id chunk) (rest cmd)
       (let* ((actor (gethash session (agent-manager-actors mgr)))
              (entry (and actor (gethash req-id (agent-actor-active-jobs actor)))))
         (when (and entry (car entry))
           (funcall (car entry) chunk)))))
    (:job-done
     (destructuring-bind (session req-id status value) (rest cmd)
       (let* ((actor (gethash session (agent-manager-actors mgr)))
              (entry (and actor (gethash req-id (agent-actor-active-jobs actor)))))
         (when entry
           (remhash req-id (agent-actor-active-jobs actor))
           (when (cdr entry)
             (funcall (cdr entry) status value))))))))

;;;; Periodic timer advancement (coalescer flush & effect timeout)

(defun agent-advance-timers (mgr now)
  "Flush expired delta coalescers and expire timed-out editor effects cleanly."
  (maphash
   (lambda (_session actor)
     (declare (ignore _session))
     (let ((coal-dl (agent-actor-coal-deadline actor)))
       (when (and coal-dl (>= now coal-dl))
         (agent-coalescer-flush mgr actor)))
     (let ((expired '()))
       (maphash (lambda (eid eff)
                  (when (>= now (agent-effect-deadline eff))
                    (push (cons eid eff) expired)))
                (agent-actor-effects-by-id actor))
       (dolist (pair expired)
         (let* ((eid (car pair))
                (eff (cdr pair))
                (call (gethash (agent-effect-call-id eff) (agent-actor-calls-by-id actor))))
           (remhash eid (agent-actor-effects-by-id actor))
           (agent-emit-turn-event mgr actor
                                  (list :turn-id (agent-actor-turn-id actor)
                                        :step (agent-actor-step actor)
                                        :type :effect-timeout
                                        :effect-id eid
                                        :call-id (agent-effect-call-id eff)
                                        :tool (agent-effect-tool eff)))
           (when (and call (eq (agent-call-status call) :awaiting-effect))
             (agent-settle-call
              mgr actor call
              (format nil "Editor effect ~A timed out after ~As"
                      (agent-effect-tool eff)
                      (or (agent-actor-effect-timeout actor) *agent-effect-timeout*))
              t))))))
   (agent-manager-actors mgr)))

(defun agent-next-timeout-seconds (mgr now)
  "Compute seconds until next coalescer or effect deadline across MGR's actors, or nil."
  (let ((min-dl nil))
    (flet ((consider (dl)
             (when dl
               (setf min-dl (if min-dl (min min-dl dl) dl)))))
      (maphash (lambda (_session actor)
                 (declare (ignore _session))
                 (consider (agent-actor-coal-deadline actor))
                 (maphash (lambda (_eid eff)
                            (declare (ignore _eid))
                            (consider (agent-effect-deadline eff)))
                          (agent-actor-effects-by-id actor)))
               (agent-manager-actors mgr)))
    (when min-dl
      (let ((rem (- min-dl now)))
        (if (<= rem 0)
            0.001d0
            (max 0.001d0 (/ (coerce rem 'double-float)
                            (coerce internal-time-units-per-second 'double-float))))))))

(defun agent-manager-loop (mgr)
  "Dedicated single-actor event loop `P_agents'."
  (let ((inbox (agent-manager-inbox mgr)))
    (loop
      (when (agent-manager-stopping mgr)
        (return))
      (let* ((now (agent-now))
             (timeout (agent-next-timeout-seconds mgr now)))
        (multiple-value-bind (msg ok) (mbox-recv inbox :timeout timeout)
          (when ok
            (agent-handle-command mgr msg)
            (loop for extra in (mbox-drain inbox 64)
                  until (agent-manager-stopping mgr)
                  do (agent-handle-command mgr extra)))
          (unless (agent-manager-stopping mgr)
            (agent-advance-timers mgr (agent-now))))))))

;;;; Manager startup and programmatic helpers

(defun start-agent-manager (kernel)
  "Start `P_agents' actor thread for KERNEL and return its `agent-manager-handle'."
  (let* ((inbox (make-mbox :name "lispm-kernel agents"))
         (mgr (%make-agent-manager kernel inbox))
         (thread (sb-thread:make-thread #'agent-manager-loop
                                        :name "lispm-kernel agents"
                                        :arguments (list mgr))))
    (make-agent-manager-handle
     thread
     (lambda (cmd) (mbox-send inbox cmd))
     (lambda () (mbox-send inbox '(:stop)))
     (lambda (session &optional since-seq)
       (if (cancelled-p (kernel-closed kernel))
           nil
           (let ((reply (make-mbox :name "agent-snapshot-reply")))
             (mbox-send inbox (list :agent-resync-sync session since-seq reply))
             (mbox-recv reply :timeout 5))))
     (lambda ()
       (if (cancelled-p (kernel-closed kernel))
           nil
           (let ((reply (make-mbox :name "agent-list-reply")))
             (mbox-send inbox (list :agent-list-sync reply))
             (mbox-recv reply :timeout 5)))))))

(defun kernel-agent-snapshot (kernel session &optional since-seq)
  "Synchronously fetch SESSION's control-plane snapshot plist from KERNEL."
  (let ((agents (kernel-agents kernel)))
    (when agents
      (funcall (agent-manager-handle-snapshot-fn agents) session since-seq))))

(defun kernel-agent-list (kernel)
  "Synchronously fetch summary plists of all agent sessions in KERNEL."
  (let ((agents (kernel-agents kernel)))
    (when agents
      (funcall (agent-manager-handle-list-fn agents)))))

(setf *agent-manager-starter* #'start-agent-manager)
