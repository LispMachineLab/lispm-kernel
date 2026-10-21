;;;; sessions.lisp --- The agents' sessions, read from their transcripts

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

;;; The job scan-sessions finds the Codex or Claude Code sessions under a
;;; directory as LispM Desktop's own readers find them, in
;;; lispm-desktop-agent-codex.el, lispm-desktop-agent-claude.el and
;;; lispm-desktop-ai.el, which are the reference for what is read here:
;;;
;;;   Codex   rollout-*.jsonl, any case, in the tree below the root,
;;;           symbolic links to directories not followed.  The session
;;;           is its head's first session_meta, titled by its head's first
;;;           prompt a person typed, or by its thread name in Codex's
;;;           session index, which wins; untitled ones are left out.
;;;   Claude  PROJECT/*.jsonl below the root.  The session is named by
;;;           its file, titled by the last custom title or summary of its
;;;           head and tail, else its head's first prompt, or by the
;;;           custom-title.json beside it, which wins.
;;;
;;; A transcript's head is its first 64 KiB, its tail its last 16 KiB
;;; after that, lines cut at either end left out.  Each transcript read is
;;; kept with its stamp, so another scan reads only those that changed;
;;; a complete scan forgets those it did not see.  Transcripts are read
;;; on several threads at once.  Of the sessions of one id, the newest
;;; transcript's is kept.
;;;
;;; Sessions go to Emacs in chunks, lists of
;;;
;;;   (:id ID :cwd CWD :title TITLE :file FILE :mtime NANOSECONDS [:started TIMESTAMP])
;;;
;;; and the result is the scan's summary, a plist of counts.

(in-package #:lispm-kernel/sessions)

(defconstant +head-bytes+ 65536
  "Bytes read from the start of a transcript, as LispM Desktop reads.")

(defconstant +tail-bytes+ 16384
  "Bytes read from the end of a transcript, as LispM Desktop reads.")

(defparameter *max-depth* 32
  "How deep below the root Codex's tree is walked.")

(defparameter *max-entries* 1000000
  "Directory entries a scan looks at, at most; past them it is truncated.")

(defparameter *max-cached* 100000
  "Transcripts, and title files, kept per agent and root, at most.")

(defparameter *max-title-length* 4096
  "Characters of a title sent to Emacs, at most.")

(defparameter *max-index-bytes* (* 16 1024 1024)
  "Bytes of Codex's session index read, at most, from its end.")

(defparameter *max-title-file-bytes* (* 1024 1024)
  "Bytes of a custom-title.json read, at most; a longer one has no title.")

(defparameter *chunk-length* 32768
  "Characters of sessions sent to Emacs in one chunk, about.")

(defparameter *threads* 4
  "Threads reading the transcripts of one scan.")

(defstruct (session (:constructor make-session (id cwd title file mtime &optional started))
                    (:copier nil))
  (id "" :type string :read-only t)
  (cwd "" :type string :read-only t)
  (title nil :type (or null string) :read-only t)
  (file "" :type string :read-only t)
  (mtime 0 :type integer :read-only t)
  (started nil :type (or null string) :read-only t))

;;;; As LispM Desktop reads transcripts

(defun whitespacep (character)
  (member character '(#\Space #\Tab #\Newline #\Return)))

(defun prefixp (prefix string &key (start 0))
  (let ((end (+ start (length prefix))))
    (and (<= end (length string))
         (string= prefix string :start2 start :end2 end))))

(defun human-text-p (text)
  "Return true when TEXT reads as a prompt a person typed.
Agents inject context, command echoes and reminders as tagged blocks
that start with <, and Codex injects project guidance headed
# AGENTS.md; those are no prompts.  So `lispm-desktop-agent-human-text-p'."
  (and (stringp text)
       (let ((start (position-if-not #'whitespacep text)))
         (and start
              (char/= (char text start) #\<)
              (not (prefixp "# AGENTS.md" text :start start))))))

(defun content-text (content)
  "Return the text of message CONTENT, a string or a list of typed parts.
So `lispm-desktop-agent-content-text'."
  (cond ((stringp content) content)
        ((listp content)
         (with-output-to-string (output)
           (dolist (part content)
             (let ((text (json-get part "text")))
               (when (stringp text)
                 (write-string text output))))))
        (t "")))

(defun blankp (string)
  (every #'whitespacep string))

(defun file-name-base (path)
  "Return the name of PATH without its directory and its last extension,
as Emacs's `file-name-base' does: a name starting with its only dot keeps it."
  (let* ((name (subseq path (1+ (or (position #\/ path :from-end t) -1))))
         (dot (position #\. name :from-end t)))
    (if (and dot (plusp dot))
        (subseq name 0 dot)
        name)))

(defun file-directory (path)
  (subseq path 0 (or (position #\/ path :from-end t) 0)))

(defun ascii-compact (string)
  "Return STRING as a base string when it is ASCII, to keep it in a quarter
of the room."
  (if (and string (every (lambda (character) (< (char-code character) 128)) string))
      (coerce string 'simple-base-string)
      string))

;;;; Lines, parsed when asked for

(defstruct (lines (:constructor %make-lines (texts values)) (:copier nil))
  (texts #() :type simple-vector :read-only t)
  (values #() :type simple-vector :read-only t))

(defun make-lines (texts)
  (let ((texts (coerce texts 'simple-vector)))
    (%make-lines texts (make-array (length texts) :initial-element '%unparsed))))

(defun line-object (lines index)
  "Return the JSON value of line INDEX of LINES, nil when it is not JSON.
Each line is parsed once, when first asked for."
  (let ((value (svref (lines-values lines) index)))
    (if (eq value '%unparsed)
        (setf (svref (lines-values lines) index)
              (handler-case (parse-json (svref (lines-texts lines) index))
                (json-error () nil)))
        value)))

(defun line-count (lines)
  (length (lines-texts lines)))

(defun first-line (lines function &key from-end)
  "Return the first true value of FUNCTION on the lines' JSON values, in
order or FROM-END."
  (let ((count (line-count lines)))
    (loop for step from 0 below count
          for index = (if from-end (- count step 1) step)
          thereis (funcall function (line-object lines index)))))

;;;; Codex

(defun codex-name-p (name)
  "Return true for a name of a Codex transcript, rollout-*.jsonl in any case."
  (let ((length (length name)))
    (and (>= length 14)
         (string-equal "rollout-" name :end2 8)
         (string-equal ".jsonl" name :start2 (- length 6))
         (not (find #\Newline name)))))

(defun codex-prompt (object)
  "Return the prompt a person typed that Codex transcript OBJECT carries."
  (let* ((payload (json-get object "payload"))
         (type (json-get object "type"))
         (payload-type (json-get payload "type")))
    (cond ((and (equal type "event_msg") (equal payload-type "user_message"))
           (let ((text (json-get payload "message")))
             (and (human-text-p text) text)))
          ((and (equal type "response_item") (equal payload-type "message")
                (equal (json-get payload "role") "user"))
           (let ((text (content-text (json-get payload "content"))))
             (and (human-text-p text) text))))))

(defun codex-session (path head stamp)
  "Return the Codex session of transcript PATH, whose head lines are HEAD."
  (let* ((meta (first-line head (lambda (object)
                                  (and (equal (json-get object "type") "session_meta") object))))
         (payload (json-get meta "payload"))
         (id (json-get payload "id"))
         (cwd (json-get payload "cwd")))
    (when (and (stringp id) (stringp cwd))
      (let ((timestamp (json-get payload "timestamp")))
        (make-session id cwd (first-line head #'codex-prompt) path (stamp-mtime stamp)
                      (and (stringp timestamp) timestamp))))))

(defun codex-files (root)
  "Return the Codex transcripts below ROOT, how many names could not be
decoded, and whether the walk was cut short.
They come in the order `directory-files-recursively' gives them: in each
directory, by name, a directory's name ending with a slash, the
transcripts below its directories before its own."
  (let ((entries 0) (undecodable 0) (truncated nil))
    (labels ((walk (directory depth)
               (checkpoint)
               (multiple-value-bind (names bad listed) (directory-names (if (string= directory "") "/" directory))
                 (incf undecodable bad)
                 (unless listed
                   (if (zerop depth)
                       (error "~A cannot be listed" root)
                       (setf truncated t))
                   (return-from walk '()))
                 (let ((below '()) (own '()))
                   (dolist (entry (sort (mapcar (lambda (name) (codex-entry directory name)) names)
                                        #'string< :key #'first))
                     (when (> (incf entries) *max-entries*)
                       (setf truncated t)
                       (return))
                     (destructuring-bind (key path kind) entry
                       (declare (ignore key))
                       (case kind
                         (:directory
                          (if (< depth *max-depth*)
                              (setf below (nconc below (walk path (1+ depth))))
                              (setf truncated t)))
                         ;; A link to a directory is neither walked nor a transcript.
                         (:linked-directory)
                         ((nil))
                         (t (when (codex-name-p (subseq path (1+ (length directory))))
                              (push path own))))))
                   (nconc below (nreverse own))))))
      (values (walk root 0) undecodable truncated))))

(defun codex-entry (directory name)
  "Return (KEY PATH KIND) of entry NAME of DIRECTORY: KEY, NAME as Emacs
sorts it, with a slash after a directory's; KIND :directory,
:linked-directory, nil when it vanished, else the kind of its stamp."
  (let* ((path (concatenate 'string directory "/" name))
         (stamp (file-stamp path :follow nil))
         (kind (and stamp (stamp-kind stamp))))
    (when (eq kind :symlink)
      (let ((target (file-stamp path)))
        (when (and target (eq (stamp-kind target) :directory))
          (setf kind :linked-directory))))
    (list (if (member kind '(:directory :linked-directory))
              (concatenate 'string name "/")
              name)
          path kind)))

(defun codex-names (cache index)
  "Return a table from Codex session id to its latest thread name, as
INDEX, Codex's session index, has them."
  (let ((stamp (and index (file-stamp index))))
    (if (not (and stamp (eq (stamp-kind stamp) :regular)))
        (make-hash-table :test 'equal)
        (multiple-value-bind (names found) (cached cache 'index index stamp)
          (if found
              names
              (multiple-value-bind (octets read-stamp cut) (read-file-octets index *max-index-bytes*)
                (let ((names (make-hash-table :test 'equal)))
                  (when octets
                    (dolist (line (octet-lines octets :drop-first cut))
                      (let* ((object (handler-case (parse-json line) (json-error () nil)))
                             (id (json-get object "id"))
                             (name (json-get object "thread_name")))
                        (when (and (stringp id) (stringp name))
                          (setf (gethash id names) (ascii-compact name)))))
                    (store cache 'index index read-stamp names))
                  names)))))))

;;;; Claude Code

(defun jsonl-name-p (name)
  (let ((length (length name)))
    (and (>= length 6)
         (string= ".jsonl" name :start2 (- length 6)))))

(defun claude-files (root)
  "Return the Claude Code transcripts below ROOT, how many names could not
be decoded, and whether a project could not be listed."
  (multiple-value-bind (projects undecodable listed) (directory-names (if (string= root "") "/" root))
    (unless listed
      (error "~A cannot be listed" root))
    ;; In the order `file-expand-wildcards' gives them: by project, then name.
    (let ((files '()) (truncated nil))
      (dolist (project (sort projects #'string<))
        (checkpoint)
        (let* ((directory (concatenate 'string root "/" project))
               (stamp (file-stamp directory)))
          (when (and stamp (eq (stamp-kind stamp) :directory))
            (multiple-value-bind (names bad listed) (directory-names directory)
              (incf undecodable bad)
              (if listed
                  (dolist (name (sort names #'string<))
                    (when (jsonl-name-p name)
                      (push (concatenate 'string directory "/" name) files)))
                  (setf truncated t))))))
      (values (nreverse files) undecodable truncated))))

(defun claude-session (path head tail stamp)
  "Return the Claude Code session of transcript PATH, whose head and tail
lines are HEAD and TAIL."
  (flet ((latest-title (lines)
           (first-line lines (lambda (object)
                               (let ((custom (json-get object "customTitle"))
                                     (summary (json-get object "summary")))
                                 (cond ((stringp custom) custom)
                                       ((and (equal (json-get object "type") "summary")
                                             (stringp summary))
                                        summary))))
                       :from-end t))
         (cwd (lines)
           (first-line lines (lambda (object)
                               (let ((cwd (json-get object "cwd")))
                                 (and (stringp cwd) cwd))))))
    (let ((title (or (and tail (latest-title tail)) (latest-title head)))
          (prompt (first-line head (lambda (object)
                                     (and (equal (json-get object "type") "user")
                                          (not (json-get object "isMeta"))
                                          (let ((text (content-text
                                                       (json-get (json-get object "message") "content"))))
                                            (and (human-text-p text) text))))))
          (cwd (or (cwd head) (and tail (cwd tail)))))
      (when (and cwd (or title prompt))
        (make-session (file-name-base path) cwd (or title prompt) path (stamp-mtime stamp))))))

(defun custom-title (octets)
  "Return the custom title of a custom-title.json holding OCTETS, or nil."
  (let ((object (handler-case
                    (parse-json (sb-ext:octets-to-string octets :external-format '(:utf-8 :replacement #\REPLACEMENT_CHARACTER))
                                :trailing t)
                  (json-error () nil))))
    (let ((title (json-get object "customTitle")))
      (and (stringp title) (not (blankp title)) title))))

(defun claude-custom-title (cache session)
  "Return the title chosen for Claude Code SESSION in the custom-title.json
of its own directory, beside its transcript, or nil."
  (let* ((path (concatenate 'string (file-directory (session-file session)) "/"
                            (session-id session) "/custom-title.json"))
         (stamp (file-stamp path)))
    (when (and stamp (eq (stamp-kind stamp) :regular))
      (multiple-value-bind (title found) (cached cache 'titles path stamp)
        (if found
            (values title path)
            (multiple-value-bind (octets read-stamp cut) (read-file-octets path *max-title-file-bytes*)
              (let ((title (and octets (not cut) (ascii-compact (custom-title octets)))))
                (when read-stamp
                  (store cache 'titles path read-stamp title))
                (values title path))))))))

;;;; What is kept between scans

(defstruct (cache (:constructor make-cache ()) (:copier nil))
  (lock (sb-thread:make-mutex :name "sessions cache") :read-only t)
  ;; Each a table from a file to (STAMP . WHAT-WAS-READ).
  (transcripts (make-hash-table :test 'equal) :read-only t)
  (titles (make-hash-table :test 'equal) :read-only t)
  (index (make-hash-table :test 'equal) :read-only t))

(defvar *caches* (make-hash-table :test 'equal)
  "The cache of each agent and root, by (AGENT . ROOT).")

(defvar *caches-lock* (sb-thread:make-mutex :name "sessions caches"))

(defun agent-cache (agent root)
  (sb-thread:with-mutex (*caches-lock*)
    (let ((key (cons agent root)))
      (or (gethash key *caches*)
          (setf (gethash key *caches*) (make-cache))))))

(defun clear-caches ()
  "Forget every transcript and title read."
  (sb-thread:with-mutex (*caches-lock*)
    (clrhash *caches*)))

(pushnew 'clear-caches *cache-clearers*)

(defun cache-table (cache which)
  (ecase which
    (transcripts (cache-transcripts cache))
    (titles (cache-titles cache))
    (index (cache-index cache))))

(defun cached (cache which file stamp)
  "Return what was read of FILE when it had STAMP, and true; else nil, nil."
  (sb-thread:with-mutex ((cache-lock cache))
    (let ((entry (gethash file (cache-table cache which))))
      (if (and entry (stamp= (car entry) stamp))
          (values (cdr entry) t)
          (values nil nil)))))

(defun store (cache which file stamp value)
  "Keep VALUE as what was read of FILE when it had STAMP, room allowing."
  (sb-thread:with-mutex ((cache-lock cache))
    (let ((table (cache-table cache which)))
      (when (or (gethash file table) (< (hash-table-count table) *max-cached*))
        (setf (gethash file table) (cons stamp value))))))

(defun sweep (cache which seen)
  "Forget the files of CACHE's table WHICH that SEEN, a table, does not have."
  (sb-thread:with-mutex ((cache-lock cache))
    (let ((table (cache-table cache which)))
      (loop for file in (loop for file being the hash-keys of table collect file)
            unless (gethash file seen)
              do (remhash file table)))))

;;;; Scanning

(defun compact-session (session)
  (when session
    (make-session (ascii-compact (session-id session)) (ascii-compact (session-cwd session))
                  (ascii-compact (session-title session)) (ascii-compact (session-file session))
                  (session-mtime session) (ascii-compact (session-started session)))))

(defun transcript-session (cache agent path)
  "Return what transcript PATH is, (STATUS . SESSION): STATUS is :read,
:cached or :skipped, SESSION its session or nil."
  (checkpoint)
  (let ((stamp (file-stamp path)))
    (if (not (and stamp (eq (stamp-kind stamp) :regular)))
        (cons :skipped nil)
        (multiple-value-bind (session found) (cached cache 'transcripts path stamp)
          (if found
              (cons :cached session)
              (multiple-value-bind (head tail read-stamp)
                  ;; Codex's sessions are all in the head.
                  (read-head-and-tail path +head-bytes+ (if (eq agent :codex) 0 +tail-bytes+))
                (if (null read-stamp)
                    (cons :skipped nil)
                    (let ((session (compact-session
                                    (if (eq agent :codex)
                                        (codex-session path (make-lines head) read-stamp)
                                        (claude-session path (make-lines head)
                                                        (and tail (make-lines tail)) read-stamp)))))
                      (store cache 'transcripts path read-stamp session)
                      (cons :read session)))))))))

(defun truncate-title (title)
  (if (> (length title) *max-title-length*)
      (subseq title 0 *max-title-length*)
      title))

(defun session-row (session title)
  (list* :id (session-id session) :cwd (session-cwd session) :title (truncate-title title)
         :file (session-file session) :mtime (session-mtime session)
         (and (session-started session) (list :started (session-started session)))))

(defun row-length (row)
  (+ 64 (loop for item in row when (stringp item) sum (length item))))

(defun emit-rows (rows emit)
  "Give EMIT the ROWS in chunks of about `*chunk-length*' characters."
  (let ((chunk '()) (length 0))
    (dolist (row rows)
      (push row chunk)
      (incf length (row-length row))
      (when (>= length *chunk-length*)
        (funcall emit (nreverse chunk))
        (setf chunk '() length 0)))
    (when chunk
      (funcall emit (nreverse chunk)))))

(defun newest-per-id (pairs)
  "Return PAIRS, (SESSION . TITLE), keeping the newest transcript of each id,
in the order each id first comes, as LispM Desktop's hash table has them."
  (let ((latest (make-hash-table :test 'equal))
        (ids '()))
    (dolist (pair pairs)
      (let* ((id (session-id (car pair)))
             (seen (gethash id latest)))
        (unless seen
          (push id ids))
        (when (or (null seen) (> (session-mtime (car pair)) (session-mtime (car seen))))
          (setf (gethash id latest) pair))))
    (mapcar (lambda (id) (gethash id latest)) (nreverse ids))))

(defun normalize-root (root)
  "Return ROOT without trailing slashes, \"\" for /."
  (string-right-trim "/" root))

(defun scan (agent root &key index (emit #'emit))
  "Find AGENT's sessions below ROOT, give them to EMIT in chunks and return
the summary (:files :rows :empty :skipped :cached :truncated).
AGENT is :codex or :claude; INDEX is Codex's session index, if any.
Signal an error when ROOT is no directory that can be listed."
  (let* ((root (normalize-root root))
         (stamp (file-stamp (if (string= root "") "/" root))))
    (unless (and stamp (eq (stamp-kind stamp) :directory))
      (error "~A is no directory" root))
    (multiple-value-bind (files undecodable truncated)
        (ecase agent
          (:codex (codex-files root))
          (:claude (claude-files root)))
      (let* ((cache (agent-cache agent root))
             (results (parallel-map (lambda (path) (transcript-session cache agent path))
                                    files :threads *threads*))
             (names (and (eq agent :codex) (codex-names cache index)))
             (titles-seen (make-hash-table :test 'equal))
             (empty 0) (skipped undecodable) (from-cache 0)
             (pairs '()))
        (loop for (status . session) in results
              do (case status
                   (:skipped (incf skipped))
                   (:cached (incf from-cache)))
                 (cond ((null session)
                        (unless (eq status :skipped) (incf empty)))
                       ((eq agent :codex)
                        (let ((title (or (gethash (session-id session) names) (session-title session))))
                          (if title
                              (push (cons session title) pairs)
                              (incf empty))))
                       (t
                        (checkpoint)
                        (multiple-value-bind (custom path) (claude-custom-title cache session)
                          (when path
                            (setf (gethash path titles-seen) t))
                          (push (cons session (or custom (session-title session))) pairs)))))
        (setf pairs (nreverse pairs))
        (unless truncated
          (let ((seen (make-hash-table :test 'equal)))
            (dolist (file files)
              (setf (gethash file seen) t))
            (sweep cache 'transcripts seen)
            (sweep cache 'titles titles-seen)))
        (let ((rows (mapcar (lambda (pair) (session-row (car pair) (cdr pair)))
                            (newest-per-id pairs))))
          (emit-rows rows emit)
          (list :files (length files) :rows (length rows) :empty empty :skipped skipped
                :cached from-cache :truncated (and truncated t)))))))

(define-job (scan-sessions :class :io) (input)
  "Find the sessions of INPUT's :agent, codex or claude, below its :root,
with Codex's session index :index; see `scan'."
  (destructuring-bind (&key agent root index) input
    (unless (member agent '(:codex :claude))
      (error "There is no agent ~S to read sessions of" agent))
    (unless (stringp root)
      (error "The root to read sessions in is ~S, no directory name" root))
    (scan agent root :index (and (stringp index) index))))
