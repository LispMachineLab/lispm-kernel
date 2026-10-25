;;;; sessions-test.lisp --- Tests of reading the agents' sessions

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

;;; What LispM Desktop's own readers make of these transcripts is checked
;;; against what the kernel makes of them in test/lispm-kernel-desktop-test.el;
;;; here, the kernel alone.

(in-package #:lispm-kernel/test)

(defun json-string (text)
  "Return TEXT as a JSON string."
  (with-output-to-string (output)
    (write-char #\" output)
    (loop for character across text
          do (case character
               (#\" (write-string "\\\"" output))
               (#\\ (write-string "\\\\" output))
               (#\Newline (write-string "\\n" output))
               (t (write-char character output))))
    (write-char #\" output)))

(defun codex-meta (id cwd &optional (timestamp "2026-10-21T01:00:00Z"))
  (format nil "{\"timestamp\":~A,\"type\":\"session_meta\",\"payload\":{\"id\":~A,\"cwd\":~A,\"timestamp\":~A}}"
          (json-string timestamp) (json-string id) (json-string cwd) (json-string timestamp)))

(defun codex-typed (text)
  (format nil "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":~A}}"
          (json-string text)))

(defun codex-said (text)
  (format nil "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":~A}]}}"
          (json-string text)))

(defun claude-user (text &key cwd meta)
  (format nil "{\"type\":\"user\",~@[\"isMeta\":true,~*~]~@[\"cwd\":~A,~]\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":~A}]}}"
          meta (and cwd (json-string cwd)) (json-string text)))

(defun padding (count)
  "Return COUNT lines of an assistant's, a hundred bytes each."
  (loop repeat count
        collect (format nil "{\"type\":\"assistant\",\"x\":\"~A\"}" (make-string 74 :initial-element #\y))))

(defun scan-rows (agent root &rest options)
  "Return the rows a scan of ROOT emits, by id, and its summary."
  (let ((rows '()))
    (let ((summary (apply #'lispm-kernel/sessions:scan agent root
                          :emit (lambda (chunk) (setf rows (append rows chunk)))
                          options)))
      (values (sort rows #'string< :key (lambda (row) (getf row :id))) summary))))

(defun row (id rows)
  (find id rows :key (lambda (row) (getf row :id)) :test #'string=))

(deftest sessions-desktop-text-rules ()
  (is (lispm-kernel/sessions:human-text-p "  fix it"))
  (is (not (lispm-kernel/sessions:human-text-p (format nil " ~%<environment_context>"))))
  (is (not (lispm-kernel/sessions:human-text-p "# AGENTS.md instructions")))
  (is (lispm-kernel/sessions:human-text-p "## AGENTS.md"))
  (is (not (lispm-kernel/sessions:human-text-p (format nil " ~C~%" #\Tab))))
  (is (not (lispm-kernel/sessions:human-text-p nil)))
  (is (string= "ab" (lispm-kernel/sessions:content-text
                     (parse-json "[{\"text\":\"a\"},{\"type\":\"image\"},\"x\",{\"text\":\"b\"}]"))))
  (is (string= "" (lispm-kernel/sessions:content-text (parse-json "{\"text\":\"a\"}"))))
  (is (string= "abc" (lispm-kernel/sessions:file-name-base "/x/y/abc.jsonl")))
  (is (string= "a.b" (lispm-kernel/sessions:file-name-base "a.b.jsonl")))
  (is (string= ".jsonl" (lispm-kernel/sessions:file-name-base "/x/.jsonl"))))

(defun codex-fixture (directory)
  "Write a Codex tree in DIRECTORY; return its root and index."
  (let ((root (path directory "sessions"))
        (outside (path directory "outside")))
    (set-mtime (write-file (path root "2026/10/21/rollout-a.jsonl")
                           (codex-meta "a" "/p/a")
                           (codex-said "<environment_context>here</environment_context>")
                           (codex-typed "# AGENTS.md for here")
                           (codex-typed "  fix the bug"))
               1700000000)
    (set-mtime (write-file (path root "2026/10/22/rollout-a-fork.jsonl")
                           (codex-meta "a" "/p/a" "2026-10-22T02:00:00Z")
                           (codex-typed "forked"))
               1700000100)
    (write-file (path root "2026/10/21/ROLLOUT-B.JSONL") (codex-meta "b" "/p/b") (codex-said "hello b"))
    (write-file (path root "2026/10/21/notes.jsonl") (codex-meta "n" "/p/n") (codex-typed "not one"))
    (write-file (path root "2026/10/22/rollout-c.jsonl") (codex-typed "no meta"))
    (write-file (path root "2026/10/22/rollout-d.jsonl") (codex-meta "d" "/p/d") (codex-typed "<only injected>"))
    (write-file (path root "2026/10/22/rollout-e.jsonl") (codex-meta "e" "/p/e"))
    (make-directory (path root "2026/rollout-dir.jsonl"))
    (write-file (path outside "rollout-z.jsonl") (codex-meta "z" "/p/z") (codex-typed "not walked"))
    (write-file (path outside "y.jsonl") (codex-meta "y" "/p/y") (codex-typed "linked y"))
    (sb-posix:symlink outside (path root "linked"))
    (sb-posix:symlink (path outside "y.jsonl") (path root "2026/rollout-link.jsonl"))
    (sb-posix:symlink (path outside "gone.jsonl") (path root "rollout-broken.jsonl"))
    (sb-posix:mkfifo (path root "rollout-fifo.jsonl") #o600)
    (values root
            (write-file (path directory "session_index.jsonl")
                        "{\"id\":\"a\",\"thread_name\":\"Named A old\"}"
                        "{\"id\":\"e\",\"thread_name\":\"Named E\"}"
                        "not json"
                        "{\"id\":\"a\",\"thread_name\":\"Named A\"}"))))

(deftest sessions-codex ()
  (lispm-kernel/sessions:clear-caches)
  (with-directory (directory)
    (multiple-value-bind (root index) (codex-fixture directory)
      (multiple-value-bind (rows summary) (scan-rows :codex (concatenate 'string root "/") :index index)
        (is (equal '("a" "b" "e" "y") (mapcar (lambda (row) (getf row :id)) rows)))
        (is (equal (list :id "a" :cwd "/p/a" :title "Named A"
                         :file (path root "2026/10/22/rollout-a-fork.jsonl")
                         :mtime (* 1700000100 1000000000) :started "2026-10-22T02:00:00Z")
                   (row "a" rows)))
        (is (string= "hello b" (getf (row "b" rows) :title)))
        (is (string= "Named E" (getf (row "e" rows) :title)))
        (is (string= "linked y" (getf (row "y" rows) :title)))
        (is (string= (path root "2026/rollout-link.jsonl") (getf (row "y" rows) :file)))
        (is (equal '(:files 9 :rows 4 :empty 2 :skipped 2 :cached 0 :truncated nil) summary)))
      ;; Without the index, sessions are titled by their prompts, or left out.
      (let ((rows (scan-rows :codex root)))
        (is (equal '("a" "b" "y") (mapcar (lambda (row) (getf row :id)) rows)))
        (is (string= "forked" (getf (row "a" rows) :title)))))))

(deftest sessions-codex-keeps-what-it-read ()
  (lispm-kernel/sessions:clear-caches)
  (with-directory (directory)
    (multiple-value-bind (root index) (codex-fixture directory)
      (scan-rows :codex root :index index)
      (is (eql 7 (getf (nth-value 1 (scan-rows :codex root :index index)) :cached)))
      (write-file (path root "2026/10/21/ROLLOUT-B.JSONL") (codex-meta "b" "/p/b") (codex-said "changed b"))
      (sb-posix:unlink (path root "2026/10/22/rollout-c.jsonl"))
      (multiple-value-bind (rows summary) (scan-rows :codex root :index index)
        (is (string= "changed b" (getf (row "b" rows) :title)))
        (is (eql 5 (getf summary :cached))))
      (let ((cache (lispm-kernel/sessions::agent-cache :codex root)))
        (is (= 6 (hash-table-count (lispm-kernel/sessions::cache-transcripts cache)))))
      (write-file index "{\"id\":\"b\",\"thread_name\":\"Named B\"}")
      (let ((rows (scan-rows :codex root :index index)))
        (is (string= "Named B" (getf (row "b" rows) :title)))
        (is (string= "forked" (getf (row "a" rows) :title)))))))

(deftest sessions-codex-prompt-past-the-head ()
  "Codex may record tools and instructions over the whole head before the
first prompt: it is looked for in the first MiB then, else in the tail."
  (lispm-kernel/sessions:clear-caches)
  (with-directory (directory)
    (let ((root (path directory "sessions")))
      (apply #'write-file (path root "rollout-f.jsonl")
             (codex-meta "f" "/p/f")
             (append (padding 700) (list (codex-typed "past the head") (codex-typed "later"))
                     (padding 200)))
      ;; Its line cut by the head's end.
      (write-file (path root "rollout-g.jsonl")
                  (codex-meta "g" "/p/g")
                  (concatenate 'string (codex-typed "cut by the head")
                               (make-string 70000 :initial-element #\Space)))
      (apply #'write-file (path root "rollout-h.jsonl")
             (codex-meta "h" "/p/h")
             (append (padding 10500) (list (codex-typed "past the first MiB"))
                     (padding 200) (list (codex-typed "in the tail"))))
      (apply #'write-file (path root "rollout-i.jsonl")
             (codex-meta "i" "/p/i")
             (append (padding 10500) (list (codex-typed "neither")) (padding 200)))
      (multiple-value-bind (rows summary) (scan-rows :codex root)
        (is (equal '("f" "g" "h") (mapcar (lambda (row) (getf row :id)) rows)))
        (is (string= "past the head" (getf (row "f" rows) :title)))
        (is (string= "cut by the head" (getf (row "g" rows) :title)))
        (is (string= "in the tail" (getf (row "h" rows) :title)))
        (is (equal '(:files 4 :rows 3 :empty 1 :skipped 0 :cached 0 :truncated nil) summary))))))

(defun claude-fixture (directory)
  "Write a Claude Code tree in DIRECTORY; return its root."
  (let ((root (path directory "projects"))
        (outside (path directory "elsewhere")))
    (write-file (path root "proj/s1.jsonl")
                (claude-user "<command-name>/clear</command-name>" :cwd "/c/one" :meta t)
                (claude-user "first prompt" :cwd "/c/one"))
    (apply #'write-file (path root "proj/s2.jsonl")
           (append (list (claude-user "early prompt" :cwd "/c/two")
                         "{\"type\":\"summary\",\"summary\":\"Early summary\"}")
                   (padding 800)
                   (list "{\"type\":\"summary\",\"summary\":\"Late summary\"}")
                   (padding 3)))
    (write-file (path root "proj/s3.jsonl")
                "{\"type\":\"custom-title\",\"customTitle\":\"Chosen in transcript\"}"
                (claude-user "third prompt" :cwd "/c/three"))
    (write-file (path root "proj/s3/custom-title.json") "{\"customTitle\": \"From file\"} ")
    (write-file (path root "proj/s4.jsonl") (claude-user "no cwd"))
    (write-file (path root "proj/s8.jsonl")
                "{\"type\":\"custom-title\",\"customTitle\":\"Chosen 8\"}"
                (claude-user "eighth" :cwd "/c/eight"))
    (write-file (path root "proj/s8/custom-title.json") "{\"customTitle\": \"   \"}")
    (write-file (path root "proj/S7.JSONL") (claude-user "case" :cwd "/c/seven"))
    (write-file (path root "proj/notes.txt") (claude-user "notes" :cwd "/c/notes"))
    (write-file (path root ".hidden/s5.jsonl") (claude-user "hidden" :cwd "/c/five"))
    (write-file (path root "file.jsonl") (claude-user "top" :cwd "/c/top"))
    (write-file (path outside "s6.jsonl") (claude-user "linked project" :cwd "/c/six"))
    (sb-posix:symlink outside (path root "linkedproj"))
    root))

(deftest sessions-claude ()
  (lispm-kernel/sessions:clear-caches)
  (with-directory (directory)
    (let ((root (claude-fixture directory)))
      (multiple-value-bind (rows summary) (scan-rows :claude root)
        (is (equal '("s1" "s2" "s3" "s5" "s6" "s8") (mapcar (lambda (row) (getf row :id)) rows)))
        (is (equal (list :id "s1" :cwd "/c/one" :title "first prompt" :file (path root "proj/s1.jsonl")
                         :mtime (stamp-mtime (file-stamp (path root "proj/s1.jsonl"))))
                   (row "s1" rows)))
        (is (string= "Late summary" (getf (row "s2" rows) :title)))
        (is (string= "From file" (getf (row "s3" rows) :title)))
        (is (string= "hidden" (getf (row "s5" rows) :title)))
        (is (string= (path root "linkedproj/s6.jsonl") (getf (row "s6" rows) :file)))
        (is (string= "Chosen 8" (getf (row "s8" rows) :title)))
        (is (equal '(:files 7 :rows 6 :empty 1 :skipped 0 :cached 0 :truncated nil) summary)))
      (write-file (path root "proj/s3/custom-title.json") "{\"customTitle\": \"Renamed\"}")
      (multiple-value-bind (rows summary) (scan-rows :claude root)
        (is (string= "Renamed" (getf (row "s3" rows) :title)))
        (is (eql 7 (getf summary :cached)))))))

(deftest sessions-lines-emacs-refuses ()
  (lispm-kernel/sessions:clear-caches)
  (with-directory (directory)
    (let ((root (path directory "projects")))
      ;; The later summary holds a lone surrogate: Emacs skips its line.
      (write-file (path root "p/s.jsonl")
                  "{\"type\":\"summary\",\"summary\":\"Good title\"}"
                  (claude-user "prompt" :cwd "/c/s")
                  "{\"type\":\"summary\",\"summary\":\"Bad \\ud83d title\"}"
                  "{\"type\":\"summary\",\"summary\":\"Huge\",\"n\":1e400}")
      (is (string= "Good title" (getf (row "s" (scan-rows :claude root)) :title))))))

(deftest sessions-chunks ()
  (lispm-kernel/sessions:clear-caches)
  (with-directory (directory)
    (let ((root (claude-fixture directory))
          (chunks 0))
      (let ((lispm-kernel/sessions::*chunk-length* 1))
        (lispm-kernel/sessions:scan :claude root :emit (lambda (chunk)
                                                         (incf chunks)
                                                         (is (= 1 (length chunk))))))
      (is (= 6 chunks)))))

(deftest sessions-refuse-what-is-no-directory ()
  (with-directory (directory)
    (signals error (lispm-kernel/sessions:scan :codex (path directory "missing") :emit #'identity))
    (signals error (lispm-kernel/sessions:scan :claude (write-file (path directory "f") "") :emit #'identity))))

(deftest sessions-scan-stops-when-cancelled ()
  (lispm-kernel/sessions:clear-caches)
  (with-directory (directory)
    (let* ((root (claude-fixture directory))
           (request (lispm-kernel::make-request 1 (gethash :echo lispm-kernel::*jobs*) nil 0 0 0))
           (lispm-kernel::*request* request)
           (emitted nil))
      (setf (lispm-kernel::request-cancelled request) t)
      (is (eq nil (catch 'lispm-kernel::cancelled
                    (lispm-kernel/sessions:scan :claude root :emit (lambda (chunk) (setf emitted chunk)))
                    :finished)))
      (is (eq nil emitted)))))

(deftest sessions-job ()
  (lispm-kernel/sessions:clear-caches)
  (with-directory (directory)
    (let ((root (claude-fixture directory)))
      (with-kernel (kernel collector)
        (send kernel
              (format nil "(submit 1 scan-sessions (:agent claude :root ~S))" root)
              "(submit 2 scan-sessions (:agent nobody :root \"/\"))"
              (format nil "(submit 3 scan-sessions (:agent codex :root ~S))" (path directory "missing")))
        (let* ((messages (answered collector 1 2 3))
               (rows (loop for message in messages
                           when (and (eq (first message) :chunk) (eql (second message) 1))
                             append (third message))))
          (is (= 6 (length rows)))
          (is (eq :success (third (done-of 1 messages))))
          (is (eql 6 (getf (fourth (done-of 1 messages)) :rows)))
          (is (eq :failed (third (done-of 2 messages))))
          (is (eq :failed (third (done-of 3 messages)))))))))
