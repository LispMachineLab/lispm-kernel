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
;;; delta coalescer, pending non-editor kernel sub-jobs with bounded credit
;;; backpressure, awaiting editor-only effect RPCs, approvals, and resync log.

(in-package #:lispm-kernel)

;;;; Delta coalescing (viewport-aware + outbox-backpressure aware)

(defun agent-coalescer-clear (actor)
  "Discard any un-flushed buffered deltas on ACTOR."
  (let ((coal (agent-actor-coalescer actor)))
    (setf (agent-coalescer-kind coal) nil
          (agent-coalescer-chunks coal) '()
          (agent-coalescer-bytes coal) 0
          (agent-coalescer-deadline coal) nil)))

(defun agent-coalescer-flush (mgr actor &key urgent)
  "Flush ACTOR's buffered deltas into a `turn-event', honoring outbox pressure.
When URGENT is nil and outbox is full, keep buffered text and retry on room hook."
  (let* ((coal (agent-actor-coalescer actor))
         (turn (agent-actor-turn actor))
         (kind (agent-coalescer-kind coal))
         (chunks (agent-coalescer-chunks coal)))
    (when (and kind chunks turn)
      (let ((text (sse-join-chunks chunks)))
        (if (zerop (length text))
            (agent-coalescer-clear actor)
            (let* ((log (agent-actor-resync actor))
                   (next-seq (1+ (agent-resync-log-event-seq log)))
                   (ev (list :seq next-seq
                             :epoch (kernel-epoch (agent-manager-kernel mgr))
                             :turn-id (agent-turn-id turn)
                             :step (agent-turn-step turn)
                             :type :delta :kind kind :text text))
                   (wire (message-string (list 'turn-event (agent-actor-session actor) ev)))
                   (outcome (if urgent
                                (agent-record-event mgr actor (cddr (cddr ev)) wire t)
                                (agent-record-event mgr actor (cddr (cddr ev)) wire nil))))
              (cond
                ((eq outcome :full)
                 (sb-ext:compare-and-swap (agent-manager-outbox-paused mgr) 0 1)
                 (let ((retry-ms (if (eq (agent-actor-viewport actor) :hidden)
                                     *agent-hidden-flush-ms*
                                     *agent-visible-flush-ms*)))
                   (setf (agent-coalescer-chunks coal) (list text)
                         (agent-coalescer-bytes coal) (length text)
                         (agent-coalescer-deadline coal) (agent-deadline-ms retry-ms))))
                (t
                 (agent-coalescer-clear actor)))))))))

(defun agent-coalescer-push (mgr actor kind text)
  "Buffer delta TEXT of KIND (`:text' or `:thinking'), flushing by threshold/viewport."
  (let ((turn (agent-actor-turn actor))
        (coal (agent-actor-coalescer actor)))
    (when (and turn (stringp text) (plusp (length text)))
      (ecase kind
        (:text (push text (agent-turn-text-chunks turn)))
        (:thinking (push text (agent-turn-thinking-chunks turn))))
      (when (and (agent-coalescer-kind coal)
                 (not (eq (agent-coalescer-kind coal) kind)))
        (agent-coalescer-flush mgr actor :urgent t))
      (setf (agent-coalescer-kind coal) kind)
      (push text (agent-coalescer-chunks coal))
      (incf (agent-coalescer-bytes coal) (length text))
      (unless (agent-coalescer-deadline coal)
        (let ((ms (if (eq (agent-actor-viewport actor) :hidden)
                      *agent-hidden-flush-ms*
                      *agent-visible-flush-ms*)))
          (setf (agent-coalescer-deadline coal) (agent-deadline-ms ms))))
      (let ((limit (if (eq (agent-actor-viewport actor) :hidden)
                       *agent-hidden-flush-bytes*
                       *agent-visible-flush-bytes*)))
        (when (>= (agent-coalescer-bytes coal) limit)
          (agent-coalescer-flush mgr actor))))))

;;;; Submitting & cancelling internal scheduler jobs

(defun agent-submit-job (mgr actor turn job-name input &key on-chunk on-done)
  "Submit internal JOB-NAME to `P_scheduler' for ACTOR/TURN; return ID."
  (let ((req-id (agent-manager-next-req-id mgr))
        (inbox (agent-manager-inbox mgr))
        (session (agent-actor-session actor)))
    (decf (agent-manager-next-req-id mgr))
    (setf (gethash req-id (agent-turn-active-jobs turn)) (cons on-chunk on-done))
    (post-control
     (agent-manager-kernel mgr)
     (list :submit-internal req-id job-name input
           (agent-actor-owner-id actor) 0 0
           (when on-chunk
             (lambda (chunk)
               (let ((len (if (stringp chunk) (length chunk) 0)))
                 (if (and (plusp len)
                          (not (agent-try-acquire-chunk-credit mgr len))
                          (progn
                            (sb-ext:compare-and-swap (agent-manager-reactor-waiters mgr) 0 1)
                            (not (agent-try-acquire-chunk-credit mgr len))))
                     :full
                     (progn
                       (mbox-send inbox (list :job-chunk session req-id chunk len))
                       :sent)))))
           (lambda (status value)
             (mbox-send inbox (list :job-done session req-id status value)))))
    req-id))

(defun agent-cancel-all-jobs (mgr actor)
  "Cancel all active scheduler requests owned by ACTOR's active turn."
  (let ((turn (agent-actor-turn actor)))
    (when turn
      (let ((ids (loop for id being the hash-keys of (agent-turn-active-jobs turn)
                       collect id)))
        (clrhash (agent-turn-active-jobs turn))
        (dolist (id ids)
          (post-control (agent-manager-kernel mgr) (list :cancel id))))
      (setf (agent-turn-stream-job-id turn) nil))))

;;;; Step launch & tool execution

(defun agent-handle-http-chunk (mgr actor job-id chunk)
  "Process one streamed HTTP SSE chunk CHUNK for ACTOR's current stream step."
  (let ((turn (agent-actor-turn actor)))
    (when (and turn
               (eql job-id (agent-turn-stream-job-id turn))
               (eq (agent-actor-state actor) :streaming))
      (dolist (delta (sse-feed (agent-turn-decoder turn) chunk
                               :coalesce t :emit-tool-input nil))
        (let ((kind (second delta))
              (payload (third delta)))
          (case kind
            ((:text :thinking)
             (agent-coalescer-push mgr actor kind payload))
            (:tool
             (agent-coalescer-flush mgr actor :urgent t)
             (push payload (agent-turn-tools turn))
             (agent-emit-turn-event
              mgr actor (list :turn-id (agent-turn-id turn)
                              :step (agent-turn-step turn)
                              :type :delta :kind :tool :text payload)))))))))

(defun agent-start-http-step (mgr actor)
  "Launch the current step's `:http-stream' job for ACTOR cleanly."
  (let ((turn (agent-actor-turn actor)))
    (setf (agent-actor-state actor) :streaming
          (agent-turn-decoder turn) (make-sse-decoder (agent-actor-dialect actor))
          (agent-turn-text-chunks turn) '()
          (agent-turn-thinking-chunks turn) '()
          (agent-turn-tools turn) '())
    (agent-coalescer-clear actor)
    (let* ((input (list :url (agent-turn-url turn)
                        :headers (agent-turn-headers turn)
                        :body (agent-turn-body-json turn)
                        :curl (agent-actor-curl actor)
                        :env (agent-actor-env actor)))
           (job-id nil))
      (setf job-id
            (agent-submit-job
             mgr actor turn :http-stream input
             :on-chunk (lambda (chunk)
                         (agent-handle-http-chunk mgr actor job-id chunk))
             :on-done (lambda (status value)
                        (let ((cur (agent-actor-turn actor)))
                          (when (and cur (eql job-id (agent-turn-stream-job-id cur)))
                            (setf (agent-turn-stream-job-id cur) nil)
                            (agent-handle-http-done mgr actor status value))))))
      (setf (agent-turn-stream-job-id turn) job-id))))

(defun agent-settle-call (mgr actor call result-str is-error)
  "Record outcome of CALL on ACTOR, emit `:tool-result', and advance turn if done."
  (let ((turn (agent-actor-turn actor))
        (log (agent-actor-resync actor)))
    (when turn
      (setf (agent-call-status call) :done
            (agent-call-result call) result-str
            (agent-call-is-error call) (and is-error t))
      (let ((summary (list :turn-id (agent-turn-id turn)
                           :step (agent-turn-step turn)
                           :call-id (agent-call-wire-id call)
                           :tool (agent-call-name call)
                           :host (agent-call-host call)
                           :is-error (and is-error t)
                           :result result-str)))
        (setf (agent-resync-log-completed-tools log)
              (agent-append-limited (agent-resync-log-completed-tools log) summary 64))
        (agent-emit-turn-event mgr actor (list* :type :tool-result summary)))
      (agent-maybe-finish-wave mgr actor))))

(defun agent-dispatch-kernel-tool (mgr actor call)
  "Execute kernel-hosted CALL via `P_scheduler' without blocking Emacs."
  (let ((turn (agent-actor-turn actor)))
    (multiple-value-bind (job-name job-input format-fn)
        (agent-build-kernel-tool-plan
         (agent-call-name call) (agent-call-input-json call)
         (agent-actor-root actor) (agent-actor-env actor))
      (if (null job-name)
          (agent-dispatch-editor-effect mgr actor call)
          (progn
            (setf (agent-call-status call) :running
                  (agent-call-job-id call)
                  (agent-submit-job
                   mgr actor turn job-name job-input
                   :on-chunk (when (eq job-name :exec)
                               (lambda (chunk)
                                 (when (eq (agent-call-status call) :running)
                                   (push chunk (agent-call-chunks call)))))
                   :on-done (lambda (status value)
                              (when (and (eq (agent-actor-turn actor) turn)
                                         (eq (agent-call-status call) :running))
                                (multiple-value-bind (text err-p)
                                    (funcall format-fn status value (agent-call-chunks call))
                                  (agent-settle-call mgr actor call text err-p)))))))))))

(defun agent-dispatch-editor-effect (mgr actor call)
  "Emit typed `editor-effect-request' to Emacs and track deadline for CALL."
  (let* ((turn (agent-actor-turn actor))
         (effect-id (agent-manager-next-effect-id mgr))
         (timeout (or (agent-actor-effect-timeout actor) *agent-effect-timeout*))
         (kind (agent-effect-kind-for-tool (agent-call-name call)))
         (eff (make-agent-effect effect-id
                                 (agent-call-id call)
                                 kind
                                 (agent-call-name call)
                                 (agent-call-input-json call)
                                 (agent-deadline-sec timeout))))
    (incf (agent-manager-next-effect-id mgr))
    (setf (agent-call-status call) :awaiting-effect
          (agent-call-effect-id call) effect-id
          (gethash effect-id (agent-turn-effects-by-id turn)) eff)
    (agent-wire-emit
     mgr (list 'editor-effect-request
               (agent-actor-session actor)
               effect-id
               kind
               (list :call-id (agent-call-wire-id call)
                     :tool (agent-call-name call)
                     :input-json (agent-call-input-json call))
               :timeout (max 1 (ceiling timeout))))))

(defun agent-dispatch-call (mgr actor call)
  "Dispatch approved CALL to either `:kernel' (unless editor fallback) or `:editor'."
  (let ((turn (agent-actor-turn actor)))
    (if (and (eq (agent-call-host call) :kernel)
             (not (agent-call-needs-editor-p
                   (agent-actor-root actor)
                   (agent-turn-unsaved-files turn)
                   (agent-call-name call)
                   (agent-call-input-json call))))
        (agent-dispatch-kernel-tool mgr actor call)
        (agent-dispatch-editor-effect mgr actor call))))

(defun agent-refresh-acting-state (actor)
  "Update ACTOR's high-level FSM state from its remaining pending calls."
  (let ((turn (agent-actor-turn actor)))
    (when (and turn
               (member (agent-actor-state actor)
                       '(:acting :awaiting-approval :awaiting-effect)))
      (setf (agent-actor-state actor)
            (cond ((some (lambda (c) (eq (agent-call-status c) :awaiting-approval))
                         (agent-turn-calls turn))
                   :awaiting-approval)
                  ((some (lambda (c) (eq (agent-call-status c) :awaiting-effect))
                         (agent-turn-calls turn))
                   :awaiting-effect)
                  (t :acting))))))

(defun agent-collect-text (blocks)
  "Concatenate `:text' blocks from BLOCKS into a single reply string."
  (apply #'concatenate 'string
         (loop for b in blocks
               when (eq (getf b :type) :text)
                 collect (or (getf b :text) ""))))

(defun agent-finish-turn-with-summary (mgr actor turn status event-type results &key stop-reason usage)
  "Record completed turn summary on ACTOR's resync log, emit EVENT-TYPE, retire turn."
  (let* ((log (agent-actor-resync actor))
         (reply (agent-collect-text (agent-turn-last-blocks turn)))
         (step (agent-turn-step turn))
         (turn-id (agent-turn-id turn))
         (summary (append (list :turn-id turn-id :step step :status status
                                :text reply :tool-results results)
                          (when stop-reason (list :stop-reason stop-reason))
                          (when usage (list :usage usage)))))
    (setf (agent-resync-log-completed-turns log)
          (agent-append-limited (agent-resync-log-completed-turns log) summary 32))
    (agent-retire-turn actor)
    (agent-emit-turn-event
     mgr actor
     (append (list :turn-id turn-id :step step :type event-type
                   :text reply :tool-results results)
             (when stop-reason (list :stop-reason stop-reason))
             (when usage (list :usage usage))))))

(defun agent-maybe-finish-wave (mgr actor)
  "If all CALLS in ACTOR's non-empty active wave settled, advance or end turn."
  (let ((turn (agent-actor-turn actor)))
    (when (and turn
               (not (agent-turn-dispatching turn))
               (member (agent-actor-state actor)
                       '(:acting :awaiting-approval :awaiting-effect))
               (consp (agent-turn-calls turn))
               (every (lambda (c) (eq (agent-call-status c) :done))
                      (agent-turn-calls turn)))
      (let* ((calls (agent-turn-calls turn))
             (blocks (agent-turn-last-blocks turn))
             (results (loop for c in calls
                            collect (list :call-id (agent-call-wire-id c)
                                          :tool (agent-call-name c)
                                          :is-error (agent-call-is-error c)
                                          :result (or (agent-call-result c) ""))))
             (records (loop for c in calls
                            collect (list :id (agent-call-wire-id c)
                                          :result (or (agent-call-result c) "")
                                          :is-error (agent-call-is-error c)))))
        (setf (agent-turn-calls turn) '())
        (clrhash (agent-turn-calls-by-id turn))
        (clrhash (agent-turn-effects-by-id turn))
        (cond
          ((not (agent-turn-auto-continue turn))
           (agent-finish-turn-with-summary mgr actor turn :done :turn-done results))
          ((>= (agent-turn-step turn) (agent-turn-max-steps turn))
           (agent-finish-turn-with-summary mgr actor turn :step-limit :step-limit results))
          (t
           (handler-case
               (let ((next-body (agent-append-next-turn-body
                                 (agent-actor-dialect actor)
                                 (agent-turn-body-json turn)
                                 blocks records)))
                 (incf (agent-turn-step turn))
                 (setf (agent-turn-body-json turn) next-body)
                 (agent-start-http-step mgr actor))
             (serious-condition (condition)
               (let ((turn-id (agent-turn-id turn))
                     (step (agent-turn-step turn)))
                 (agent-retire-turn actor)
                 (agent-emit-turn-event
                  mgr actor (list :turn-id turn-id :step step :type :turn-error
                                  :status 0 :error-type "body_build_error"
                                  :message (condition-text condition))))))))))
    (agent-refresh-acting-state actor)))

(defun agent-handle-http-done (mgr actor status value)
  "Handle completion of ACTOR's HTTP stream step and either finish or run tools."
  (agent-coalescer-flush mgr actor :urgent t)
  (let* ((turn (agent-actor-turn actor))
         (turn-id (and turn (agent-turn-id turn)))
         (step (and turn (agent-turn-step turn))))
    (when turn
      (cond
        ((eq status 'cancelled)
         (agent-retire-turn actor))
        ((eq status 'failed)
         (let* ((msg (if (stringp value) value "http-stream failed"))
                (log (agent-actor-resync actor)))
           (setf (agent-resync-log-completed-turns log)
                 (agent-append-limited (agent-resync-log-completed-turns log)
                                       (list :turn-id turn-id :step step :status :error :message msg)
                                       32))
           (agent-retire-turn actor)
           (agent-emit-turn-event mgr actor (list :turn-id turn-id :step step :type :turn-error
                                                  :status 0 :error-type "network_error"
                                                  :message msg))))
        (t
         (let ((res (sse-finish (agent-turn-decoder turn) value)))
           (if (not (getf res :ok))
               (let ((log (agent-actor-resync actor))
                     (summary (list :turn-id turn-id :step step :status :error
                                    :status-code (getf res :status)
                                    :error-type (getf res :type)
                                    :message (getf res :message))))
                 (setf (agent-resync-log-completed-turns log)
                       (agent-append-limited (agent-resync-log-completed-turns log) summary 32))
                 (agent-retire-turn actor)
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
                 (setf (agent-turn-last-blocks turn) blocks)
                 (agent-emit-turn-event mgr actor
                                        (list :turn-id turn-id :step step :type :step-response
                                              :stop-reason stop-reason :usage usage
                                              :invalid invalid :blocks blocks))
                 (if (not proceed)
                     (agent-finish-turn-with-summary
                      mgr actor turn :done :turn-done nil
                      :stop-reason stop-reason :usage usage)
                     (agent-begin-tool-wave mgr actor tool-blocks invalid))))))))))

(defun agent-unique-call-key (table base-id)
  "Return a unique lookup key for TABLE derived from BASE-ID."
  (let ((seed (if (plusp (length base-id)) base-id "call")))
    (if (not (gethash seed table))
        seed
        (loop for suffix from 2
              for candidate = (format nil "~A#~D" seed suffix)
              unless (gethash candidate table)
                do (return candidate)))))

(defun agent-begin-tool-wave (mgr actor tool-blocks invalid)
  "Create, classify, and launch all tool calls in TOOL-BLOCKS for ACTOR."
  (let ((turn (agent-actor-turn actor))
        (calls '()))
    (setf (agent-actor-state actor) :acting
          (agent-turn-calls turn) '())
    (clrhash (agent-turn-calls-by-id turn))
    (clrhash (agent-turn-effects-by-id turn))
    (dolist (b tool-blocks)
      (let* ((wire-id (or (getf b :id) ""))
             (key (agent-unique-call-key (agent-turn-calls-by-id turn) wire-id))
             (name (or (getf b :name) ""))
             (input-json (or (getf b :input-json) "{}")))
        (multiple-value-bind (host approval reasons)
            (agent-classify-tool (agent-actor-tool-policies actor) name)
          (let ((call (make-agent-call key wire-id name input-json host approval)))
            (setf (agent-call-reasons call) reasons)
            (push call calls)
            (setf (gethash key (agent-turn-calls-by-id turn)) call)))))
    (setf calls (nreverse calls)
          (agent-turn-calls turn) calls
          (agent-turn-dispatching turn) t)
    (unwind-protect
         (dolist (call calls)
           (cond
             ((member (agent-call-wire-id call) invalid :test #'string=)
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
      (when (eq (agent-actor-turn actor) turn)
        (setf (agent-turn-dispatching turn) nil)))
    (agent-refresh-acting-state actor)
    (agent-maybe-finish-wave mgr actor)))

;;;; Snapshot, resync, cancellation & command handlers

(defun agent-build-snapshot (mgr actor &optional since-seq)
  "Construct a complete reconnect/resync plist for ACTOR."
  (agent-coalescer-flush mgr actor :urgent t)
  (let* ((turn (agent-actor-turn actor))
         (log (agent-actor-resync actor))
         (pending-effects '())
         (pending-approvals '())
         (recent-events (reverse (agent-resync-log-events log))))
    (when turn
      (maphash (lambda (_id eff)
                 (declare (ignore _id))
                 (push (list :effect-id (agent-effect-id eff)
                             :call-id (agent-effect-call-id eff)
                             :kind (agent-effect-kind eff)
                             :tool (agent-effect-tool eff)
                             :input-json (agent-effect-input-json eff))
                       pending-effects))
               (agent-turn-effects-by-id turn))
      (dolist (call (agent-turn-calls turn))
        (when (eq (agent-call-status call) :awaiting-approval)
          (push (list :call-id (agent-call-id call)
                      :tool (agent-call-name call)
                      :input-json (agent-call-input-json call)
                      :reasons (agent-call-reasons call))
                pending-approvals))))
    (when (integerp since-seq)
      (setf recent-events (loop for ev in recent-events
                                when (> (getf ev :seq 0) since-seq)
                                  collect ev)))
    (list :session (agent-actor-session actor)
          :epoch (kernel-epoch (agent-manager-kernel mgr))
          :state (agent-actor-state actor)
          :dialect (agent-actor-dialect actor)
          :viewport (agent-actor-viewport actor)
          :turn-id (and turn (agent-turn-id turn))
          :step (if turn (agent-turn-step turn) 0)
          :event-seq (agent-resync-log-event-seq log)
          :stream (if turn
                      (list :text (sse-join-chunks (agent-turn-text-chunks turn))
                            :thinking (sse-join-chunks (agent-turn-thinking-chunks turn))
                            :tools (reverse (agent-turn-tools turn)))
                      (list :text (agent-resync-log-last-stream-text log)
                            :thinking (agent-resync-log-last-stream-thinking log)
                            :tools (agent-resync-log-last-stream-tools log)))
          :pending-effects (nreverse pending-effects)
          :pending-approvals (nreverse pending-approvals)
          :completed-tools (reverse (agent-resync-log-completed-tools log))
          :completed-turns (reverse (agent-resync-log-completed-turns log))
          :events recent-events)))

(defun agent-summary-list (mgr)
  "Return lightweight summary plists across all live actors in MGR."
  (let ((items '())
        (epoch (kernel-epoch (agent-manager-kernel mgr))))
    (maphash (lambda (_session actor)
               (declare (ignore _session))
               (let ((turn (agent-actor-turn actor))
                     (log (agent-actor-resync actor)))
                 (push (list :session (agent-actor-session actor)
                             :epoch epoch
                             :state (agent-actor-state actor)
                             :turn-id (and turn (agent-turn-id turn))
                             :step (if turn (agent-turn-step turn) 0)
                             :viewport (agent-actor-viewport actor)
                             :event-seq (agent-resync-log-event-seq log))
                       items)))
             (agent-manager-actors mgr))
    (sort items #'string< :key (lambda (pl) (getf pl :session)))))

(defun agent-cmd-turn (mgr actor input)
  "Handle `(:agent-turn ...)' INPUT for ACTOR."
  (when (not (eq (agent-actor-state actor) :idle))
    (agent-cmd-cancel mgr actor "Superseded by new turn."))
  (incf (agent-actor-turn-seq actor))
  (let* ((turn-id (or (and (getf input :turn-id) (princ-to-string (getf input :turn-id)))
                      (format nil "turn-~D" (agent-actor-turn-seq actor))))
         (url (or (getf input :url) (agent-actor-url actor)))
         (headers (if (agent-plist-member-p input :headers)
                      (agent-coerce-list (getf input :headers))
                      (agent-actor-headers actor)))
         (max-steps (or (and (integerp (getf input :max-steps))
                             (max 1 (getf input :max-steps)))
                        (agent-actor-max-steps actor)))
         (auto-continue (if (agent-plist-member-p input :auto-continue)
                            (and (getf input :auto-continue) t)
                            (agent-actor-auto-continue actor)))
         (body (or (getf input :body) "{}"))
         (unsaved (loop for f in (agent-coerce-list (getf input :unsaved-files))
                        when (stringp f) collect f))
         (turn (make-agent-turn turn-id url headers max-steps auto-continue body unsaved)))
    (setf (agent-actor-turn actor) turn)
    (agent-emit-turn-event mgr actor (list :turn-id turn-id :step 1 :type :turn-started))
    (agent-start-http-step mgr actor)))

(defun agent-cmd-cancel (mgr actor &optional (reason "Cancelled by client."))
  "Cancel ACTOR's active turn, sub-jobs, effects, and approvals cleanly."
  (agent-coalescer-flush mgr actor :urgent t)
  (agent-cancel-all-jobs mgr actor)
  (let ((turn (agent-actor-turn actor))
        (log (agent-actor-resync actor)))
    (if (null turn)
        (agent-retire-turn actor)
        (let ((turn-id (agent-turn-id turn))
              (step (agent-turn-step turn)))
          (dolist (call (agent-turn-calls turn))
            (unless (eq (agent-call-status call) :done)
              (setf (agent-call-status call) :done
                    (agent-call-result call) reason
                    (agent-call-is-error call) t)))
          (setf (agent-resync-log-completed-turns log)
                (agent-append-limited
                 (agent-resync-log-completed-turns log)
                 (list :turn-id turn-id :step step :status :cancelled :reason reason)
                 32))
          (agent-retire-turn actor)
          (agent-emit-turn-event mgr actor
                                 (list :turn-id turn-id :step step :type :turn-cancelled
                                       :reason reason))))))

(defun agent-handle-effect-reply-cmd (mgr actor effect-id status result)
  "Apply `:agent-effect-reply' for ACTOR/EFFECT-ID."
  (let ((turn (agent-actor-turn actor)))
    (when turn
      (let ((eff (gethash effect-id (agent-turn-effects-by-id turn))))
        (when eff
          (remhash effect-id (agent-turn-effects-by-id turn))
          (let ((call (gethash (agent-effect-call-id eff) (agent-turn-calls-by-id turn))))
            (when (and call (eq (agent-call-status call) :awaiting-effect))
              (let ((text (cond ((stringp result) result)
                                ((null result) "")
                                (t (princ-to-string result))))
                    (err-p (not (eq status :ok))))
                (agent-settle-call mgr actor call text err-p)))))))))

(defun agent-handle-approval-decision-cmd (mgr actor call-id decision reason)
  "Apply `:agent-approval-decision' for ACTOR/CALL-ID."
  (let ((turn (agent-actor-turn actor)))
    (when turn
      (let ((call (gethash call-id (agent-turn-calls-by-id turn))))
        (when (and call (eq (agent-call-status call) :awaiting-approval))
          (agent-emit-turn-event mgr actor
                                 (list :turn-id (agent-turn-id turn)
                                       :step (agent-turn-step turn)
                                       :type :approval-settled
                                       :call-id (agent-call-wire-id call)
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
              t))))))))

(defun agent-handle-client-command (mgr cmd)
  "Dispatch one control-plane message CMD sent by Emacs."
  (case (first cmd)
    (:agent-start
     (destructuring-bind (session config) (rest cmd)
       (let ((actor (agent-ensure-actor mgr session config)))
         (agent-emit-turn-event mgr actor (list :type :session-ready :dialect (agent-actor-dialect actor))))))
    (:agent-turn
     (destructuring-bind (session input) (rest cmd)
       (agent-cmd-turn mgr (agent-ensure-actor mgr session) input)))
    (:agent-cancel
     (let ((actor (gethash (second cmd) (agent-manager-actors mgr))))
       (when actor (agent-cmd-cancel mgr actor))))
    (:agent-stop
     (let* ((session (second cmd))
            (actor (gethash session (agent-manager-actors mgr))))
       (when actor
         (agent-cmd-cancel mgr actor "Session stopped.")
         (remhash session (agent-manager-actors mgr)))))
    (:agent-effect-reply
     (destructuring-bind (session effect-id status result) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr))))
         (when actor (agent-handle-effect-reply-cmd mgr actor effect-id status result)))))
    (:agent-approval-decision
     (destructuring-bind (session call-id decision reason) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr))))
         (when actor (agent-handle-approval-decision-cmd mgr actor call-id decision reason)))))
    (:agent-viewport-subscribe
     (destructuring-bind (session mode) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr))))
         (when (and actor (member mode '(:visible :hidden)))
           (setf (agent-actor-viewport actor) mode)
           (when (eq mode :visible)
             (agent-coalescer-flush mgr actor))))))
    (:agent-resync
     (destructuring-bind (session since-seq) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr)))
             (epoch (kernel-epoch (agent-manager-kernel mgr))))
         (agent-wire-emit
          mgr (list 'agent-snapshot session
                    (if actor
                        (agent-build-snapshot mgr actor since-seq)
                        (list :session session :epoch epoch :state :missing :events '())))))))
    (:agent-resync-sync
     (destructuring-bind (session since-seq reply-mbox) (rest cmd)
       (let ((actor (gethash session (agent-manager-actors mgr)))
             (epoch (kernel-epoch (agent-manager-kernel mgr))))
         (mbox-send reply-mbox
                    (if actor
                        (agent-build-snapshot mgr actor since-seq)
                        (list :session session :epoch epoch :state :missing :events '()))))))
    (:agent-list
     (agent-wire-emit mgr (list 'agent-list (agent-summary-list mgr))))
    (:agent-list-sync
     (mbox-send (second cmd) (agent-summary-list mgr)))))

(defun agent-handle-command (mgr cmd)
  "Dispatch one CSP control, outbox notification, or sub-job message CMD."
  (case (first cmd)
    (:stop
     (setf (agent-manager-stopping mgr) t)
     (maphash (lambda (_session actor)
                (declare (ignore _session))
                (agent-cancel-all-jobs mgr actor)
                (agent-coalescer-clear actor)
                (agent-retire-turn actor))
              (agent-manager-actors mgr)))
    (:outbox-room
     (maphash (lambda (_session actor)
                (declare (ignore _session))
                (agent-coalescer-flush mgr actor))
              (agent-manager-actors mgr)))
    (:job-chunk
     (destructuring-bind (session req-id chunk len) (rest cmd)
       (unwind-protect
            (let* ((actor (gethash session (agent-manager-actors mgr)))
                   (turn (and actor (agent-actor-turn actor)))
                   (entry (and turn (gethash req-id (agent-turn-active-jobs turn)))))
              (when (and entry (car entry))
                (funcall (car entry) chunk)))
         (agent-release-chunk-credit mgr (or len 0)))))
    (:job-done
     (destructuring-bind (session req-id status value) (rest cmd)
       (let* ((actor (gethash session (agent-manager-actors mgr)))
              (turn (and actor (agent-actor-turn actor)))
              (entry (and turn (gethash req-id (agent-turn-active-jobs turn)))))
         (when entry
           (remhash req-id (agent-turn-active-jobs turn))
           (when (cdr entry)
             (funcall (cdr entry) status value))))))
    (t
     (agent-handle-client-command mgr cmd))))

;;;; Periodic timer advancement (coalescer flush & effect timeout)

(defun agent-expire-actor-effects (mgr actor turn now)
  "Expire timed-out editor effects on ACTOR/TURN as of monotonic NOW."
  (let ((expired '()))
    (maphash (lambda (eid eff)
               (when (>= now (agent-effect-deadline eff))
                 (push (cons eid eff) expired)))
             (agent-turn-effects-by-id turn))
    (dolist (pair expired)
      (let* ((eid (car pair))
             (eff (cdr pair))
             (call (gethash (agent-effect-call-id eff) (agent-turn-calls-by-id turn))))
        (remhash eid (agent-turn-effects-by-id turn))
        (agent-emit-turn-event mgr actor
                               (list :turn-id (agent-turn-id turn)
                                     :step (agent-turn-step turn)
                                     :type :effect-timeout
                                     :effect-id eid
                                     :call-id (if call (agent-call-wire-id call) (agent-effect-call-id eff))
                                     :tool (agent-effect-tool eff)))
        (when (and call (eq (agent-call-status call) :awaiting-effect))
          (agent-settle-call
           mgr actor call
           (format nil "Editor effect ~A timed out after ~As"
                   (agent-effect-tool eff)
                   (or (agent-actor-effect-timeout actor) *agent-effect-timeout*))
           t))))))

(defun agent-advance-timers (mgr now)
  "Flush expired delta coalescers and expire timed-out editor effects cleanly."
  (maphash
   (lambda (_session actor)
     (declare (ignore _session))
     (let ((coal-dl (agent-coalescer-deadline (agent-actor-coalescer actor))))
       (when (and coal-dl (>= now coal-dl))
         (agent-coalescer-flush mgr actor)))
     (let ((turn (agent-actor-turn actor)))
       (when turn
         (agent-expire-actor-effects mgr actor turn now))))
   (agent-manager-actors mgr)))

(defun agent-next-timeout-seconds (mgr now)
  "Compute seconds until next coalescer or effect deadline across MGR's actors, or nil."
  (let ((min-dl nil))
    (flet ((consider (dl)
             (when dl
               (setf min-dl (if min-dl (min min-dl dl) dl)))))
      (maphash (lambda (_session actor)
                 (declare (ignore _session))
                 (consider (agent-coalescer-deadline (agent-actor-coalescer actor)))
                 (let ((turn (agent-actor-turn actor)))
                   (when turn
                     (maphash (lambda (_eid eff)
                                (declare (ignore _eid))
                                (consider (agent-effect-deadline eff)))
                              (agent-turn-effects-by-id turn)))))
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
    (credit-sink-register-room-hook
     (kernel-outbox kernel)
     (lambda ()
       (when (= 1 (sb-ext:compare-and-swap (agent-manager-outbox-paused mgr) 1 0))
         (mbox-send inbox '(:outbox-room)))))
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
