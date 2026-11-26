;;;; agent-tools.lisp --- Kernel tool classification, path safety, and JSON turn builders

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

;;; Pure domain logic and bounded `:io' file reading backing `P_agents'.
;;; Separated from `agent.lisp' so tool policy enforcement, root-relative
;;; path containment, editor-host fallback detection, and lossless
;;; multi-step JSON assembly stay isolated from actor concurrency.

(in-package #:lispm-kernel)

(defparameter *agent-default-editor-tools*
  '("read_buffer" "list_buffers" "edit_buffer" "edit_file" "write_file" "eval_elisp")
  "Tools routed to Emacs over `editor-effect-request' by default.")

(defparameter *agent-default-kernel-tools*
  '("run_shell" "search_files" "workspace_cmd" "read_file")
  "Tools eligible to execute on `lispm-kernel' worker/reactor pools.")

(defparameter *agent-safe-auto-tools*
  '("search_files" "read_file")
  "Read-only kernel tools permitted without explicit interactive approval.")

(defparameter *agent-media-extensions*
  '("png" "jpg" "jpeg" "gif" "webp" "mp4" "mov" "webm" "mkv")
  "File extensions handled by Emacs media inspection rather than kernel text read.")

;;;; Shared small coercion & clamping helpers

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

(defun agent-clamp-integer (value default min-val max-val)
  "Coerce JSON numeric VALUE to an integer clamped to [MIN-VAL, MAX-VAL]."
  (let ((parsed (sse-json-integer value)))
    (if parsed
        (min max-val (max min-val parsed))
        default)))

;;;; Path normalization, containment, and host escape checks

(defun agent-split-slash (path)
  "Split PATH on `/' characters, returning empty-free list of segments."
  (loop for start = 0 then (and sep (1+ sep))
        for sep = (and start (position #\/ path :start start))
        while start
        for seg = (subseq path start sep)
        when (plusp (length seg))
          collect seg))

(defun agent-lexical-normalize-path (path)
  "Normalize `.' and `..' components lexically in native PATH."
  (let ((abs-p (and (plusp (length path)) (char= (char path 0) #\/)))
        (stack '()))
    (dolist (seg (agent-split-slash path))
      (cond ((string= seg ".") nil)
            ((string= seg "..")
             (if (and stack (not (string= (first stack) "..")))
                 (pop stack)
                 (unless abs-p (push seg stack))))
            (t (push seg stack))))
    (let ((joined (format nil "~{~A~^/~}" (nreverse stack))))
      (cond ((and abs-p (string= joined "")) "/")
            (abs-p (concatenate 'string "/" joined))
            ((string= joined "") ".")
            (t joined)))))

(defun agent-resolve-path (root raw)
  "Resolve RAW path relative to workspace ROOT when non-absolute."
  (let* ((base (if (and (stringp root) (plusp (length root))) root "."))
         (clean-base (if (string= base "/") "/" (string-right-trim "/" base))))
    (if (not (and (stringp raw) (plusp (length raw))))
        (agent-lexical-normalize-path clean-base)
        (agent-lexical-normalize-path
         (if (char= (char raw 0) #\/)
             raw
             (if (string= clean-base "/")
                 (concatenate 'string "/" raw)
                 (concatenate 'string clean-base "/" raw)))))))

(defun agent-native-truename (path)
  "Return resolved symlink-free namestring for existing PATH, or nil."
  (handler-case
      (let* ((pn (sb-ext:parse-native-namestring path))
             (real (truename pn)))
        (let ((s (sb-ext:native-namestring real)))
          (if (string= s "/") "/" (string-right-trim "/" s))))
    ((or file-error sb-posix:syscall-error sb-int:character-encoding-error) () nil)))

(defun agent-canonicalize-with-ancestor (path)
  "Resolve existing prefix of PATH through symlinks while keeping non-existent suffix."
  (let ((norm (agent-lexical-normalize-path path)))
    (or (agent-native-truename norm)
        (let ((cur norm)
              (suffix '()))
          (loop while (and (plusp (length cur)) (not (string= cur "/")) (not (string= cur ".")))
                for slash = (position #\/ cur :from-end t)
                for parent = (if slash (if (zerop slash) "/" (subseq cur 0 slash)) ".")
                for base = (if slash (subseq cur (1+ slash)) cur)
                do (push base suffix)
                   (let ((real-parent (agent-native-truename parent)))
                     (when real-parent
                       (return-from agent-canonicalize-with-ancestor
                         (agent-resolve-path real-parent (format nil "~{~A~^/~}" suffix)))))
                   (if (or (null slash) (zerop slash))
                       (return)
                       (setf cur parent)))
          norm))))

(defun agent-path-within-root-p (root target)
  "Return true when resolved TARGET lies within resolved ROOT directory."
  (let* ((r (agent-canonicalize-with-ancestor (agent-resolve-path "." root)))
         (p (agent-canonicalize-with-ancestor (agent-resolve-path root target))))
    (and (stringp r) (stringp p)
         (or (string= p r)
             (let ((prefix (if (string= r "/") "/" (concatenate 'string r "/"))))
               (and (>= (length p) (length prefix))
                    (string= p prefix :end1 (length prefix))))))))

(defun agent-org-link-p (path)
  "Return true when PATH uses Emacs Org link notation `[[file:...]]'."
  (and (stringp path) (>= (length path) 7) (string= path "[[file:" :end1 7)))

(defun agent-media-path-p (path)
  "Return true when PATH has a known binary media extension."
  (when (stringp path)
    (let* ((slash (position #\/ path :from-end t))
           (base (if slash (subseq path (1+ slash)) path))
           (dot (position #\. base :from-end t)))
      (when (and dot (< (1+ dot) (length base)))
        (member (string-downcase (subseq base (1+ dot)))
                *agent-media-extensions*
                :test #'string=)))))

;;;; Bounded local `read-file-range' job on `:io' pool

(defun agent-format-numbered-lines (lines offset limit more-lines byte-truncated)
  "Format LINES starting at 1-based OFFSET matching Emacs `lispm-tools-number-lines'."
  (let* ((total (length lines))
         (shown (loop for l in lines for i below limit collect l))
         (n (1- offset))
         (body (format nil "~{~A~^~%~}"
                       (loop for line in shown
                             do (incf n)
                             collect (format nil "~6D~C~A" n #\Tab line))))
         (tail-lines (- total (length shown))))
    (cond
      ((and byte-truncated (or (plusp tail-lines) more-lines))
       (format nil "~A~&[... output byte budget reached; continue with offset ~D]"
               body (+ offset (length shown))))
      ((plusp tail-lines)
       (format nil "~A~&[... ~D more line~P; continue with offset ~D]"
               body tail-lines tail-lines (+ offset (length shown))))
      (more-lines
       (format nil "~A~&[... more lines follow; continue with offset ~D]"
               body (+ offset (length shown))))
      (t body))))

(defun agent-read-stream-lines (stream offset limit max-bytes)
  "Stream octets from regular STREAM collecting up to LIMIT lines from OFFSET."
  (let ((buf (make-array 65536 :element-type '(unsigned-byte 8)))
        (pending (make-array 0 :element-type '(unsigned-byte 8)))
        (line-no 0)
        (kept '())
        (kept-bytes 0)
        (byte-truncated nil)
        (more-lines nil)
        (stop-early nil))
    (flet ((consume-line (octets)
             (incf line-no)
             (cond
               ((< line-no offset) nil)
               ((< (length kept) limit)
                (let ((need (+ kept-bytes (length octets) 1)))
                  (if (and (plusp (length kept)) (> need max-bytes))
                      (setf byte-truncated t more-lines t stop-early t)
                      (let ((take (if (> (+ kept-bytes (length octets)) max-bytes)
                                      (progn (setf byte-truncated t stop-early t)
                                             (max 0 (- max-bytes kept-bytes)))
                                      (length octets))))
                        (push (lispm-kernel/files:octets-text octets 0 take) kept)
                        (incf kept-bytes (1+ take))))))
               (t
                (setf more-lines t stop-early t)))))
      (loop until stop-early
            for count = (read-sequence buf stream)
            while (plusp count)
            do (checkpoint)
               (let* ((combined (if (plusp (length pending))
                                    (concatenate '(vector (unsigned-byte 8))
                                                 pending (subseq buf 0 count))
                                    (subseq buf 0 count)))
                      (end (length combined))
                      (pos 0))
                 (loop for nl = (position 10 combined :start pos :end end)
                       while (and nl (not stop-early))
                       do (consume-line (subseq combined pos nl))
                          (setf pos (1+ nl)))
                 (setf pending (if stop-early #() (subseq combined pos end)))))
      (when (and (not stop-early) (plusp (length pending)))
        (consume-line pending))
      (values (nreverse kept) more-lines byte-truncated))))

(define-job (read-file-range :class :io) (input)
  "Read bounded numbered lines from regular file `:path' on an `:io' worker."
  (destructuring-bind (&key path (offset 1) (limit 2000) (max-bytes 262144)) input
    (check-type path string)
    (let ((off (max 1 offset))
          (lim (min 2000 (max 1 limit)))
          (cap (min 4194304 (max 1024 max-bytes))))
      (checkpoint)
      (let ((stamp0 (lispm-kernel/files:file-stamp path :follow t)))
        (when (and stamp0 (eq (lispm-kernel/files:stamp-kind stamp0) :directory))
          (job-error "~A is a directory; use list_directory" path)))
      (let ((handled nil)
            (output ""))
        (lispm-kernel/files:with-regular-file (stream stamp path)
          (when (lispm-kernel/files:stamp-p stamp)
            (setf handled t)
            (multiple-value-bind (lines more-p byte-trunc-p)
                (agent-read-stream-lines stream off lim cap)
              (setf output (agent-format-numbered-lines lines off lim more-p byte-trunc-p)))))
        (unless handled
          (job-error "Cannot read regular file: ~A" path))
        (list :path path :content output)))))

;;;; Tool classification, routing guards, and job-plan builders

(defun agent-classify-tool (policies name)
  "Return (values HOST APPROVAL REASONS) for tool NAME under POLICIES.
Safe defaults apply when POLICIES omits a tool: `read_file' and `search_files'
auto-run inside `:kernel'; `run_shell' and `workspace_cmd' require `:ask';
editor and unknown tools route to `:editor' with `:ask'."
  (let* ((plist-p (and (listp policies) (keywordp (first policies))))
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
                         ((and plist-p (member name (getf policies :auto) :test #'string=))
                          :auto)
                         ((member name *agent-safe-auto-tools* :test #'string=)
                          :auto)
                         (t :ask)))
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

(defun agent-parse-json-object (json-str)
  "Parse JSON-STR into a `json-object', returning an empty object on failure."
  (handler-case
      (let ((parsed (lispm-kernel/json:parse-json json-str :preserve-literals t)))
        (if (lispm-kernel/json:json-object-p parsed)
            parsed
            (lispm-kernel/json:make-json-object '())))
    (lispm-kernel/json:json-error ()
      (lispm-kernel/json:make-json-object '()))))

(defun agent-call-needs-editor-p (root unsaved-files tool-name input-json)
  "Return true when kernel-eligible TOOL-NAME must fall back to Emacs host."
  (cond
    ((string= tool-name "read_file")
     (let* ((obj (agent-parse-json-object input-json))
            (raw (or (lispm-kernel/json:json-get obj "path") ""))
            (resolved (agent-canonicalize-with-ancestor (agent-resolve-path root raw)))
            (unsaved-norm (mapcar (lambda (u)
                                    (agent-canonicalize-with-ancestor
                                     (agent-resolve-path root u)))
                                  unsaved-files)))
       (or (agent-org-link-p raw)
           (agent-media-path-p raw)
           (not (agent-path-within-root-p root resolved))
           (member resolved unsaved-norm :test #'string=))))
    ((string= tool-name "search_files")
     (not (null unsaved-files)))
    (t nil)))

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

(defun agent-relative-label (root file)
  "Format FILE relative to ROOT when inside ROOT."
  (let* ((r (agent-resolve-path "." root))
         (prefix (if (string= r "/") "/" (concatenate 'string r "/")))
         (f (agent-resolve-path root file)))
    (if (and (>= (length f) (length prefix))
             (string= f prefix :end1 (length prefix)))
        (subseq f (length prefix))
        f)))

(defun agent-format-search-result (status value root)
  "Format `:search-files' settlement into (values TEXT IS-ERROR-P)."
  (if (not (eq status 'success))
      (values (format nil "Search ~(~A~): ~A" status (or value "")) t)
      (let ((lines '()))
        (dolist (item (getf value :items))
          (let ((label (agent-relative-label root (getf item :file))))
            (dolist (m (getf item :matches))
              (push (format nil "~A:~D:~A" label (first m) (second m)) lines))))
        (values (if lines
                    (format nil "~{~A~^~%~}" (nreverse lines))
                    "No matches.")
                nil))))

(defun agent-build-run-shell-plan (obj root env)
  "Build kernel `:exec' plan for `run_shell' with clamped timeout and cwd."
  (let* ((cmd (or (sse-nonempty-string (lispm-kernel/json:json-get obj "command")) ""))
         (dir-raw (sse-nonempty-string (lispm-kernel/json:json-get obj "directory")))
         (dir (if dir-raw (agent-resolve-path root dir-raw) (agent-resolve-path "." root)))
         (timeout (agent-clamp-integer (lispm-kernel/json:json-get obj "timeout") 60 1 86400)))
    (values :exec
            (list :program "/bin/sh"
                  :args (list "-c" cmd)
                  :cwd dir
                  :env env
                  :env-inherit t
                  :timeout timeout
                  :combine-error t)
            #'agent-format-exec-result)))

(defun agent-build-workspace-plan (obj root env)
  "Build kernel `:exec' plan for `workspace_cmd' with resolved cwd."
  (let* ((program (or (sse-nonempty-string (lispm-kernel/json:json-get obj "program")) "git"))
         (args-raw (agent-coerce-list (lispm-kernel/json:json-get obj "args")))
         (args (loop for a in args-raw collect (if (stringp a) a (princ-to-string a))))
         (dir-raw (sse-nonempty-string (lispm-kernel/json:json-get obj "directory")))
         (dir (if dir-raw (agent-resolve-path root dir-raw) (agent-resolve-path "." root)))
         (timeout (agent-clamp-integer (lispm-kernel/json:json-get obj "timeout") 60 1 86400)))
    (values :exec
            (list :program program
                  :args args
                  :cwd dir
                  :env env
                  :env-inherit t
                  :search (not (and (plusp (length program)) (char= (char program 0) #\/)))
                  :timeout timeout
                  :combine-error t)
            #'agent-format-exec-result)))

(defun agent-build-search-plan (obj root)
  "Build kernel `:search-files' plan with ROOT-relative entry normalization."
  (let* ((pattern (or (sse-nonempty-string (lispm-kernel/json:json-get obj "pattern")) ""))
         (dir-raw (or (sse-nonempty-string (lispm-kernel/json:json-get obj "path"))
                      (sse-nonempty-string (lispm-kernel/json:json-get obj "directory"))))
         (dir (if dir-raw (agent-resolve-path root dir-raw) (agent-resolve-path "." root)))
         (files-raw (agent-coerce-list (lispm-kernel/json:json-get obj "files")))
         (raw-entries (or (loop for f in files-raw
                                when (stringp f)
                                  collect (agent-resolve-path root f))
                          (list dir)))
         (files (loop for entry in raw-entries
                      for stamp = (lispm-kernel/files:file-stamp entry :follow t)
                      collect (if (and stamp (eq (lispm-kernel/files:stamp-kind stamp) :directory))
                                  (ensure-trailing-slash entry)
                                  entry)))
         (glob (sse-nonempty-string (lispm-kernel/json:json-get obj "glob")))
         (case-fold (or (eq (lispm-kernel/json:json-get obj "ignore_case") t)
                        (eq (lispm-kernel/json:json-get obj "case_fold") t)))
         (max-matches (agent-clamp-integer
                       (lispm-kernel/json:json-get obj "max_matches") 200 1 10000)))
    (values :search-files
            (list :files files
                  :pattern pattern
                  :case-fold (and case-fold t)
                  :glob glob
                  :glob-dir (ensure-trailing-slash (agent-resolve-path "." root))
                  :max-matches max-matches)
            (lambda (status value _chunks)
              (declare (ignore _chunks))
              (agent-format-search-result status value root)))))

(defun agent-build-read-file-plan (obj root)
  "Build kernel `:read-file-range' plan respecting OFFSET, LIMIT, and ROOT."
  (let* ((raw-path (or (sse-nonempty-string (lispm-kernel/json:json-get obj "path")) ""))
         (path (agent-resolve-path root raw-path))
         (offset (agent-clamp-integer (lispm-kernel/json:json-get obj "offset") 1 1 10000000))
         (limit (agent-clamp-integer (lispm-kernel/json:json-get obj "limit") 2000 1 2000)))
    (values :read-file-range
            (list :path path :offset offset :limit limit :max-bytes 262144)
            (lambda (status value _chunks)
              (declare (ignore _chunks))
              (if (eq status 'success)
                  (values (or (getf value :content) "") nil)
                  (values (format nil "read_file ~(~A~): ~A" status (or value "")) t))))))

(defun agent-build-kernel-tool-plan (name input-json root env)
  "Return (values JOB-NAME JOB-INPUT FORMAT-FN) for kernel tool NAME, or nil."
  (let ((obj (agent-parse-json-object input-json)))
    (cond
      ((string= name "run_shell") (agent-build-run-shell-plan obj root env))
      ((string= name "workspace_cmd") (agent-build-workspace-plan obj root env))
      ((string= name "search_files") (agent-build-search-plan obj root))
      ((string= name "read_file") (agent-build-read-file-plan obj root))
      (t nil))))

;;;; Lossless multi-step JSON body assembly

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
                (setf pairs (append pairs (list (cons "signature" (getf b :signature))))))
              (lispm-kernel/json:make-json-object pairs)))
           ((eq btype :tool-use)
            (let* ((json-str (or (getf b :input-json) "{}"))
                   (parsed (agent-parse-json-object json-str)))
              (lispm-kernel/json:make-json-object
               (list (cons "type" "tool_use")
                     (cons "id" (or (getf b :id) ""))
                     (cons "name" (or (getf b :name) ""))
                     (cons "input" parsed)))))
           ((and (eq btype :other) (getf b :json))
            (agent-parse-json-object (getf b :json)))
           (t
            (lispm-kernel/json:make-json-object
             (list (cons "type" "text")
                   (cons "text" (or (getf b :text) "")))))))
   'simple-vector))

(defun agent-calls-to-anthropic-results (call-records)
  "Convert finished CALL-RECORDS plists (`:id', `:result', `:is-error') to JSON."
  (coerce
   (loop for rec in call-records
         collect (lispm-kernel/json:make-json-object
                  (append (list (cons "type" "tool_result")
                                (cons "tool_use_id" (getf rec :id))
                                (cons "content" (or (getf rec :result) "")))
                          (when (getf rec :is-error)
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

(defun agent-append-next-turn-body (dialect body-json blocks call-records)
  "Append BLOCKS assistant turn and CALL-RECORDS tool results to BODY-JSON."
  (let* ((doc (lispm-kernel/json:parse-json body-json :preserve-literals t))
         (pairs (lispm-kernel/json:json-object-pairs doc))
         (messages-pair (assoc "messages" pairs :test #'string=))
         (old-msgs (if messages-pair (agent-coerce-list (cdr messages-pair)) '()))
         (new-msgs
           (ecase dialect
             (:anthropic
              (list
               (lispm-kernel/json:make-json-object
                (list (cons "role" "assistant")
                      (cons "content" (agent-blocks-to-anthropic-content blocks))))
               (lispm-kernel/json:make-json-object
                (list (cons "role" "user")
                      (cons "content" (agent-calls-to-anthropic-results call-records))))))
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
                       (loop for rec in call-records
                             collect (lispm-kernel/json:make-json-object
                                      (list (cons "role" "tool")
                                            (cons "tool_call_id" (getf rec :id))
                                            (cons "content" (or (getf rec :result) "")))))))
                (cons (lispm-kernel/json:make-json-object assistant-pairs) tool-msgs)))))
         (updated-vec (coerce (append old-msgs new-msgs) 'simple-vector))
         (updated-pairs (loop for pair in pairs
                              collect (if (string= (car pair) "messages")
                                          (cons "messages" updated-vec)
                                          pair))))
    (unless messages-pair
      (setf updated-pairs (append updated-pairs (list (cons "messages" updated-vec)))))
    (lispm-kernel/json:encode-json (lispm-kernel/json:make-json-object updated-pairs))))

;;;; Actor data structures, timers, bounded credit & wire helpers

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

(defparameter *agent-chunk-limit* (* 4 1024 1024)
  "Byte credit limit on internal reactor chunks queued toward `P_agents'.")

(defstruct (agent-effect (:constructor make-agent-effect
                          (id call-id kind tool input-json deadline))
                         (:copier nil))
  "One outstanding Kernel -> Emacs `editor-effect-request'."
  (id 0 :type integer :read-only t)
  (call-id "" :type string :read-only t)
  (kind :tool :type keyword :read-only t)
  (tool "" :type string :read-only t)
  (input-json "{}" :type string :read-only t)
  (deadline 0 :type integer :read-only t))

(defstruct (agent-call (:constructor make-agent-call
                        (id wire-id name input-json host approval))
                       (:copier nil))
  "One `tool_use' call tracked within an active turn step."
  (id "" :type string :read-only t)
  (wire-id "" :type string :read-only t)
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

(defstruct (agent-coalescer (:constructor make-agent-coalescer ()) (:copier nil))
  "Per-session delta buffer coalescing text/thinking by viewport cadence."
  (kind nil :type (or null keyword))
  (chunks '() :type list)
  (bytes 0 :type fixnum)
  (deadline nil :type (or null integer)))

(defstruct (agent-resync-log (:constructor make-agent-resync-log ()) (:copier nil))
  "Bounded reconnect history retained per session across `:idle' transitions."
  (event-seq 0 :type integer)
  (events '() :type list)
  (completed-tools '() :type list)
  (completed-turns '() :type list)
  (last-stream-text "" :type string)
  (last-stream-thinking "" :type string)
  (last-stream-tools '() :type list))

(defstruct (agent-turn (:constructor make-agent-turn
                        (id url headers max-steps auto-continue body-json unsaved-files))
                       (:copier nil))
  "Transient active turn state, released cleanly upon returning to `:idle'."
  (id "" :type string :read-only t)
  (step 1 :type integer)
  (url "" :type string :read-only t)
  (headers '() :type list)
  (max-steps 16 :type integer :read-only t)
  (auto-continue t :type boolean :read-only t)
  (body-json "{}" :type string)
  (unsaved-files '() :type list)
  (stream-job-id nil :type (or null integer))
  (decoder nil)
  (text-chunks '() :type list)
  (thinking-chunks '() :type list)
  (tools '() :type list)
  (last-blocks '() :type list)
  (active-jobs (make-hash-table :test 'eql) :read-only t)
  (calls '() :type list)
  (calls-by-id (make-hash-table :test 'equal) :read-only t)
  (effects-by-id (make-hash-table :test 'eql) :read-only t)
  (dispatching nil :type boolean))

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
  (turn-seq 0 :type integer)
  (coalescer (make-agent-coalescer) :type agent-coalescer :read-only t)
  (turn nil :type (or null agent-turn))
  (resync (make-agent-resync-log) :type agent-resync-log :read-only t))

(defstruct (agent-manager (:constructor %make-agent-manager (kernel inbox))
                          (:copier nil))
  "Single-owner coordinator running on the `P_agents' thread."
  (kernel nil :type kernel :read-only t)
  (inbox nil :type mbox :read-only t)
  (actors (make-hash-table :test 'equal) :read-only t)
  (next-req-id -1 :type integer)
  (next-owner-id -1 :type integer)
  (next-effect-id 1 :type integer)
  (pending-chunk-bytes 0 :type sb-ext:word)
  (reactor-waiters 0 :type sb-ext:word)
  (outbox-paused 0 :type sb-ext:word)
  (stopping nil :type boolean))

(defun agent-now ()
  "Current monotonic timestamp in SBCL internal time units."
  (get-internal-real-time))

(defun agent-deadline-ms (ms)
  "Convert MS milliseconds from now into an internal-time-units deadline."
  (+ (agent-now) (ceiling (* ms internal-time-units-per-second) 1000)))

(defun agent-deadline-sec (sec)
  "Convert SEC seconds from now into an internal-time-units deadline."
  (+ (agent-now) (max 1 (round (* sec internal-time-units-per-second)))))

(defun agent-take-first (list limit)
  "Return a fresh list holding at most LIMIT leading elements of LIST."
  (loop for item in list for i below limit collect item))

(defun agent-append-limited (list item limit)
  "Prepend ITEM to LIST returning at most LIMIT elements non-destructively."
  (agent-take-first (cons item list) limit))

(defun agent-wire-emit (mgr form)
  "Send control wire FORM asynchronously via `P_writer' without blocking."
  (credit-sink-put-control (kernel-outbox (agent-manager-kernel mgr))
                           (message-string form)))

(defun agent-record-event (mgr actor event-plist wire-string &optional urgent)
  "Record EVENT-PLIST on ACTOR's resync log and send pre-encoded WIRE-STRING."
  (let* ((log (agent-actor-resync actor))
         (seq (1+ (agent-resync-log-event-seq log)))
         (outbox (kernel-outbox (agent-manager-kernel mgr)))
         (full (list* :seq seq :epoch (kernel-epoch (agent-manager-kernel mgr)) event-plist))
         (wire (or wire-string
                   (message-string (list 'turn-event (agent-actor-session actor) full)))))
    (if urgent
        (progn
          (setf (agent-resync-log-event-seq log) seq
                (agent-resync-log-events log)
                (agent-append-limited (agent-resync-log-events log) full *agent-max-events*))
          (credit-sink-put-control outbox wire)
          :sent)
        (let ((outcome (credit-sink-try-put-chunk outbox wire :limit *outbox-limit*)))
          (when (eq outcome :sent)
            (setf (agent-resync-log-event-seq log) seq
                  (agent-resync-log-events log)
                  (agent-append-limited (agent-resync-log-events log) full *agent-max-events*)))
          outcome))))

(defun agent-emit-turn-event (mgr actor event-plist)
  "Assign sequence number and emit urgent lifecycle `(turn-event ...)'."
  (let* ((log (agent-actor-resync actor))
         (seq (incf (agent-resync-log-event-seq log)))
         (full (list* :seq seq :epoch (kernel-epoch (agent-manager-kernel mgr)) event-plist)))
    (setf (agent-resync-log-events log)
          (agent-append-limited (agent-resync-log-events log) full *agent-max-events*))
    (agent-wire-emit mgr (list 'turn-event (agent-actor-session actor) full))
    full))

(defun agent-try-acquire-chunk-credit (mgr bytes)
  "Atomically reserve BYTES in `P_agents' chunk budget when room allows."
  (declare (type agent-manager mgr) (type sb-ext:word bytes))
  (let ((limit (max 1 *agent-chunk-limit*)))
    (loop
      (let ((cur (agent-manager-pending-chunk-bytes mgr)))
        (when (and (plusp cur) (> (+ cur bytes) limit))
          (return nil))
        (when (eql cur (sb-ext:compare-and-swap (agent-manager-pending-chunk-bytes mgr)
                                                cur (+ cur bytes)))
          (return t))))))

(defun agent-release-chunk-credit (mgr bytes)
  "Return BYTES to `P_agents' chunk budget and wake paused reactor if ready."
  (declare (type agent-manager mgr) (type sb-ext:word bytes))
  (when (plusp bytes)
    (let* ((old (sb-ext:atomic-decf (agent-manager-pending-chunk-bytes mgr) bytes))
           (new (- old bytes))
           (half (ash (max 2 *agent-chunk-limit*) -1)))
      (when (and (< new half)
                 (= 1 (sb-ext:compare-and-swap (agent-manager-reactor-waiters mgr) 1 0)))
        (let ((reactor (kernel-reactor (agent-manager-kernel mgr))))
          (when reactor
            (funcall (reactor-handle-wake-fn reactor))))))))

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

(defun agent-snapshot-turn-stream (actor)
  "Persist active turn stream buffers into ACTOR's resync log before clearing turn."
  (let ((turn (agent-actor-turn actor))
        (log (agent-actor-resync actor)))
    (when turn
      (setf (agent-resync-log-last-stream-text log)
            (sse-join-chunks (agent-turn-text-chunks turn))
            (agent-resync-log-last-stream-thinking log)
            (sse-join-chunks (agent-turn-thinking-chunks turn))
            (agent-resync-log-last-stream-tools log)
            (reverse (agent-turn-tools turn))))))

(defun agent-retire-turn (actor)
  "Transition ACTOR to `:idle', snapshot stream, and drop sensitive turn state."
  (agent-snapshot-turn-stream actor)
  (setf (agent-actor-state actor) :idle
        (agent-actor-turn actor) nil))
