;;;; search.lisp --- Parallel local file search for Emacs

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

;;; Emacs searches local files by reading them one after another into a
;;; buffer on its own thread.  The search-files job searches them in the
;;; kernel instead, across its :cpu threads, while leaving remote TRAMP
;;; files and unsaved Emacs buffers to Emacs:
;;;
;;;   Emacs  (submit 8 search-files
;;;                  (:files ("/path/a.el" "/path/sub/")
;;;                   :pattern "\\(defun foo-(a|b)\\b"
;;;                   :case-fold nil :glob "*.el" :glob-dir "/path/"
;;;                   :open-files ("/path/a.el")
;;;                   :max-file-size 1048576 :max-matches 200))
;;;   kernel (done 8 success
;;;                (:items ((:file "/path/a.el" :open t)
;;;                         (:file "/path/sub/b.el" :matches ((2 "(defun foo-b ()"))))
;;;                 :large 0))

(in-package #:lispm-kernel)

(defparameter *excluded-directories*
  '("CVS" "RCS" "SCCS" "_darcs" "{arch}" ".git" ".hg" ".svn" ".bzr" "_MTN"
    "node_modules" "vendor" "dist" "build" "target" "venv" "__pycache__")
  "Directory names that directory expansion in search-files skips.")

;;;; Character classes and word boundaries

(defun word-char-p (char)
  "Return true when CHAR is a word constituent: alphanumeric or underscore."
  (or (alphanumericp char) (char= char #\_)))

(defun whitespace-char-p (char)
  "Return true when CHAR is a whitespace character."
  (member char '(#\Space #\Tab #\Newline #\Return #\Page #\Vt)))

(defun hex-digit-char-p (char)
  (and (digit-char-p char 16) t))

(defun posix-class-p (name char)
  "Return true when CHAR belongs to the POSIX class NAME."
  (cond ((string= name "alnum") (alphanumericp char))
        ((string= name "alpha") (alpha-char-p char))
        ((string= name "digit") (and (digit-char-p char) t))
        ((string= name "space") (whitespace-char-p char))
        ((string= name "blank") (or (char= char #\Space) (char= char #\Tab)))
        ((string= name "upper") (upper-case-p char))
        ((string= name "lower") (lower-case-p char))
        ((string= name "word") (word-char-p char))
        ((string= name "xdigit") (hex-digit-char-p char))
        ((string= name "ascii") (< (char-code char) 128))
        ((string= name "cntrl") (or (< (char-code char) 32) (= (char-code char) 127)))
        ((string= name "print") (and (>= (char-code char) 32) (/= (char-code char) 127)))
        ((string= name "graph") (and (> (char-code char) 32) (/= (char-code char) 127)))
        ((string= name "punct")
         (and (> (char-code char) 32) (/= (char-code char) 127) (not (alphanumericp char))))
        (t nil)))

(defun char-matches-spec-p (char spec case-fold)
  "Return true when CHAR matches one bracket element SPEC."
  (cond ((characterp spec)
         (if case-fold (char-equal char spec) (char= char spec)))
        ((and (consp spec) (eq (first spec) :range))
         (let ((low (second spec))
               (high (third spec)))
           (if case-fold
               (or (char<= (char-downcase low) (char-downcase char) (char-downcase high))
                   (char<= (char-upcase low) (char-upcase char) (char-upcase high)))
               (char<= low char high))))
        ((and (consp spec) (eq (first spec) :posix))
         (let ((name (second spec)))
           (if (and case-fold (or (string= name "upper") (string= name "lower")))
               (alpha-char-p char)
               (posix-class-p name char))))
        (t nil)))

;;;; Regular expression parser (ripgrep / grep -E subset matching lispm-tools)

(defun parse-bracket (pattern start)
  "Parse [...] starting at START in PATTERN; return (values NODE NEXT-INDEX)."
  (let ((i (1+ start))
        (n (length pattern))
        (negated nil)
        (raw '()))
    (when (and (< i n) (char= (char pattern i) #\^))
      (setf negated t)
      (incf i))
    (when (and (< i n) (char= (char pattern i) #\]))
      (push #\] raw)
      (incf i))
    (loop
      (when (>= i n)
        (error "Unterminated [ in ~A" pattern))
      (let ((c (char pattern i)))
        (cond ((char= c #\])
               (incf i)
               (return))
              ((and (char= c #\[) (< (1+ i) n) (char= (char pattern (1+ i)) #\:))
               (let ((close (search ":]" pattern :start2 (+ i 2))))
                 (unless close
                   (error "Unterminated [: in ~A" pattern))
                 (push (list :posix (subseq pattern (+ i 2) close)) raw)
                 (setf i (+ close 2))))
              ((char= c #\\)
               (when (>= (1+ i) n)
                 (error "Unterminated [ in ~A" pattern))
               (let ((d (char pattern (1+ i))))
                 (incf i 2)
                 (case d
                   (#\d (push '(:posix "digit") raw))
                   (#\s (push '(:posix "space") raw))
                   (#\w (push '(:posix "alnum") raw) (push #\_ raw))
                   (#\t (push #\Tab raw))
                   (#\n (push #\Newline raw))
                   (#\r (push #\Return raw))
                   ((#\D #\S #\W) (error "\\~C inside [...] is not supported" d))
                   (otherwise (push d raw)))))
              (t
               (push c raw)
               (incf i)))))
    ;; Assemble character ranges C1 - C2 from the flat items.
    (let ((items (nreverse raw))
          (specs '()))
      (loop while items
            do (let ((first (pop items)))
                 (if (and (characterp first)
                          (consp items)
                          (eql (first items) #\-)
                          (consp (rest items))
                          (characterp (second items)))
                     (progn
                       (pop items)
                       (push (list :range first (pop items)) specs))
                     (push first specs))))
      (values (list :class negated (nreverse specs)) i))))

(defun parse-interval (pattern start)
  "If PATTERN at START has {m}, {m,} or {m,n} with at least one digit,
return (values MIN MAX END); else nil."
  (let* ((n (length pattern))
         (close (and (< (1+ start) n) (position #\} pattern :start (1+ start)))))
    (when (and close (> close (1+ start)))
      (let* ((body (subseq pattern (1+ start) close))
             (comma (position #\, body)))
        (when (and (every (lambda (ch) (or (digit-char-p ch) (char= ch #\,))) body)
                   (some #'digit-char-p body)
                   (<= (count #\, body) 1))
          (if comma
              (let ((min-str (subseq body 0 comma))
                    (max-str (subseq body (1+ comma))))
                (values (if (zerop (length min-str)) 0 (parse-integer min-str))
                        (if (zerop (length max-str)) nil (parse-integer max-str))
                        (1+ close)))
              (let ((exact (parse-integer body)))
                (values exact exact (1+ close)))))))))

(defun parse-regex (pattern)
  "Parse PATTERN into an AST node."
  (let ((n (length pattern))
        (i 0)
        (group-count 0))
    (labels ((parse-alt (stop-at- close-ok)
               (let ((left (parse-seq stop-at- close-ok)))
                 (loop while (and (< i n) (char= (char pattern i) #\|))
                       do (incf i)
                          (setf left (list :alt left (parse-seq stop-at- close-ok))))
                 left))
             (parse-seq (stop-at- close-ok)
               (let ((nodes '()))
                 (loop while (< i n)
                       for c = (char pattern i)
                       until (or (char= c #\|) (and stop-at- (char= c #\))))
                       do (when (and (char= c #\)) (not close-ok))
                            (error "Unmatched ) in ~A" pattern))
                          (push (parse-quantified) nodes))
                 (cond ((null nodes) '(:empty))
                       ((null (rest nodes)) (first nodes))
                       (t (cons :seq (nreverse nodes))))))
             (parse-quantified ()
               (let ((atom (parse-atom)))
                 (loop while (< i n)
                       for c = (char pattern i)
                       do (cond ((member c '(#\* #\+ #\?))
                                 (incf i)
                                 (let ((greedy t))
                                   (when (and (< i n) (char= (char pattern i) #\?))
                                     (setf greedy nil)
                                     (incf i))
                                   (setf atom
                                         (ecase c
                                           (#\* (list :rep atom 0 nil greedy))
                                           (#\+ (list :rep atom 1 nil greedy))
                                           (#\? (list :rep atom 0 1 greedy))))))
                                ((char= c #\{)
                                 (multiple-value-bind (min max end) (parse-interval pattern i)
                                   (if end
                                       (let ((greedy t))
                                         (setf i end)
                                         (when (and (< i n) (char= (char pattern i) #\?))
                                           (setf greedy nil)
                                           (incf i))
                                         (setf atom (list :rep atom min max greedy)))
                                       (return))))
                                (t (return))))
                 atom))
             (parse-atom ()
               (let ((c (char pattern i)))
                 (cond ((char= c #\^) (incf i) '(:bol))
                       ((char= c #\$) (incf i) '(:eol))
                       ((char= c #\.) (incf i) '(:any))
                       ((char= c #\[)
                        (multiple-value-bind (node next) (parse-bracket pattern i)
                          (setf i next)
                          node))
                       ((char= c #\()
                        (cond ((and (<= (+ i 3) n) (string= pattern "(?:" :start1 i :end1 (+ i 3)))
                               (incf i 3)
                               (let ((inner (parse-alt t t)))
                                 (unless (and (< i n) (char= (char pattern i) #\)))
                                   (error "Unterminated ( in ~A" pattern))
                                 (incf i)
                                 (list :group nil inner)))
                              ((and (<= (+ i 2) n) (string= pattern "(?" :start1 i :end1 (+ i 2)))
                               (error "(?...) groups other than (?:...), such as lookaround, are not supported: ~A"
                                      pattern))
                              (t
                               (incf i)
                               (let* ((idx (incf group-count))
                                      (inner (parse-alt t t)))
                                 (unless (and (< i n) (char= (char pattern i) #\)))
                                   (error "Unterminated ( in ~A" pattern))
                                 (incf i)
                                 (list :group idx inner)))))
                       ((char= c #\\)
                        (when (= (1+ i) n)
                          (error "Trailing backslash in ~A" pattern))
                        (let ((d (char pattern (1+ i))))
                          (incf i 2)
                          (cond ((char= d #\d) '(:class nil ((:posix "digit"))))
                                ((char= d #\D) '(:class t ((:posix "digit"))))
                                ((char= d #\s) '(:class nil ((:posix "space"))))
                                ((char= d #\S) '(:class t ((:posix "space"))))
                                ((char= d #\w) '(:class nil ((:posix "alnum") #\_)))
                                ((char= d #\W) '(:class t ((:posix "alnum") #\_)))
                                ((char= d #\b) '(:boundary :b))
                                ((char= d #\B) '(:boundary :not-b))
                                ((char= d #\<) '(:boundary :word-start))
                                ((char= d #\>) '(:boundary :word-end))
                                ((char= d #\t) '(:lit #\Tab))
                                ((char= d #\n) '(:lit #\Newline))
                                ((char= d #\r) '(:lit #\Return))
                                ((char<= #\1 d #\9)
                                 (list :backref (- (char-code d) (char-code #\0))))
                                (t (list :lit d)))))
                       (t (incf i) (list :lit c))))))
      (parse-alt nil nil))))

;;;; Matching an AST against a line

(defun boundary-matches-p (kind line pos len)
  (let ((before (and (> pos 0) (word-char-p (char line (1- pos)))))
        (after (and (< pos len) (word-char-p (char line pos)))))
    (ecase kind
      (:b (not (eq before after)))
      (:not-b (eq before after))
      (:word-start (and (not before) after))
      (:word-end (and before (not after))))))

(defun match-node (node line pos len case-fold groups cont)
  "Return true when NODE matches LINE at POS and CONT succeeds on the end."
  (ecase (first node)
    (:empty (funcall cont pos))
    (:bol (and (= pos 0) (funcall cont pos)))
    (:eol (and (= pos len) (funcall cont pos)))
    (:any (and (< pos len) (funcall cont (1+ pos))))
    (:lit
     (let ((ch (second node)))
       (and (< pos len)
            (if case-fold
                (char-equal (char line pos) ch)
                (char= (char line pos) ch))
            (funcall cont (1+ pos)))))
    (:boundary
     (and (boundary-matches-p (second node) line pos len)
          (funcall cont pos)))
    (:class
     (let ((negated (second node))
           (specs (third node)))
       (and (< pos len)
            (let* ((ch (char line pos))
                   (in (some (lambda (spec) (char-matches-spec-p ch spec case-fold)) specs)))
              (if negated (not in) in))
            (funcall cont (1+ pos)))))
    (:seq
     (labels ((match-seq (rest-nodes current)
                (if (null rest-nodes)
                    (funcall cont current)
                    (match-node (first rest-nodes) line current len case-fold groups
                                (lambda (next) (match-seq (rest rest-nodes) next))))))
       (match-seq (rest node) pos)))
    (:alt
     (or (match-node (second node) line pos len case-fold groups cont)
         (match-node (third node) line pos len case-fold groups cont)))
    (:group
     (let ((idx (second node))
           (inner (third node)))
       (if (and idx (<= 1 idx 9))
           (let ((old (aref groups idx)))
             (unwind-protect
                  (match-node inner line pos len case-fold groups
                              (lambda (end-pos)
                                (setf (aref groups idx) (cons pos end-pos))
                                (funcall cont end-pos)))
               (setf (aref groups idx) old)))
           (match-node inner line pos len case-fold groups cont))))
    (:backref
     (let* ((idx (second node))
            (span (and (<= 1 idx 9) (aref groups idx))))
       (when span
         (let* ((gstart (car span))
                (gend (cdr span))
                (glen (- gend gstart)))
           (and (<= (+ pos glen) len)
                (if case-fold
                    (string-equal line line :start1 pos :end1 (+ pos glen) :start2 gstart :end2 gend)
                    (string= line line :start1 pos :end1 (+ pos glen) :start2 gstart :end2 gend))
                (funcall cont (+ pos glen)))))))
    (:rep
     (destructuring-bind (inner min max greedy) (rest node)
       (labels ((repeat (current count)
                  (cond ((and max (> count max)) nil)
                        ((< count min)
                         (match-node inner line current len case-fold groups
                                     (lambda (next)
                                       (if (and (= next current) (>= (1+ count) min))
                                           (funcall cont next)
                                           (repeat next (1+ count))))))
                        (greedy
                         (or (and (or (null max) (< count max))
                                  (match-node inner line current len case-fold groups
                                              (lambda (next)
                                                (and (> next current)
                                                     (repeat next (1+ count))))))
                             (funcall cont current)))
                        (t
                         (or (funcall cont current)
                             (and (or (null max) (< count max))
                                  (match-node inner line current len case-fold groups
                                              (lambda (next)
                                                (and (> next current)
                                                     (repeat next (1+ count)))))))))))
         (repeat pos 0))))))

(defun extract-required-literal (node)
  "Return the longest contiguous literal substring required by NODE, or nil."
  (labels ((collect-literals (nodes)
             (let ((best "")
                   (current (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
               (flet ((flush ()
                        (when (> (length current) (length best))
                          (setf best (copy-seq current)))
                        (setf (fill-pointer current) 0)))
                 (dolist (item nodes)
                   (if (and (consp item) (eq (first item) :lit))
                       (vector-push-extend (second item) current)
                       (flush)))
                 (flush))
               (and (plusp (length best)) best))))
    (cond ((eq (first node) :lit) (string (second node)))
          ((eq (first node) :seq) (collect-literals (rest node)))
          ((and (eq (first node) :group) (consp (third node)))
           (extract-required-literal (third node)))
          (t nil))))

(defun compile-matcher (pattern case-fold &key anchored)
  "Return a function (lambda (line) -> boolean) testing whether LINE matches PATTERN."
  (let* ((ast (parse-regex pattern))
         (literal (extract-required-literal ast))
         (pure-literal-p (and (not anchored)
                              (or (eq (first ast) :lit)
                                  (and (eq (first ast) :seq)
                                       (every (lambda (x) (and (consp x) (eq (first x) :lit)))
                                              (rest ast)))))))
    (cond (pure-literal-p
           (let ((needle (or literal "")))
             (lambda (line)
               (and (search needle line :test (if case-fold #'char-equal #'char=)) t))))
          (t
           (lambda (line)
             (let ((len (length line)))
               (when (or (null literal)
                         (search literal line :test (if case-fold #'char-equal #'char=)))
                 (let ((groups (make-array 10 :initial-element nil)))
                   (if anchored
                       (and (match-node ast line 0 len case-fold groups (lambda (end) (= end len))) t)
                       (loop for start from 0 to len
                             thereis (match-node ast line start len case-fold groups
                                                 (lambda (_end) (declare (ignore _end)) t))))))))))))

;;;; Globs and directories

(defun glob-to-regex (glob)
  "Translate GLOB into an unanchored regex string."
  (let ((i 0)
        (n (length glob))
        (out (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
    (labels ((emit-str (s)
               (loop for ch across s do (vector-push-extend ch out))))
      (loop while (< i n)
            for c = (char glob i)
            do (cond ((and (<= (+ i 3) n) (string= glob "**/" :start1 i :end1 (+ i 3)))
                      (emit-str "(?:.*/)?")
                      (incf i 3))
                     ((and (<= (+ i 2) n) (string= glob "**" :start1 i :end1 (+ i 2)))
                      (emit-str ".*")
                      (incf i 2))
                     ((char= c #\*)
                      (emit-str "[^/]*")
                      (incf i))
                     ((char= c #\?)
                      (emit-str "[^/]")
                      (incf i))
                     ((and (char= c #\{) (position #\} glob :start i))
                      (let* ((close (position #\} glob :start i))
                             (parts (let ((sub (subseq glob (1+ i) close))
                                          (acc '())
                                          (start 0))
                                      (loop for comma = (position #\, sub :start start)
                                            do (push (subseq sub start (or comma (length sub))) acc)
                                            while comma
                                            do (setf start (1+ comma)))
                                      (nreverse acc))))
                        (emit-str "(?:")
                        (loop for (part . more) on parts
                              do (emit-str (glob-to-regex part))
                                 (when more (emit-str "|")))
                        (emit-str ")")
                        (setf i (1+ close))))
                     ((and (char= c #\[) (< (1+ i) n) (position #\] glob :start (+ i 2)))
                      (let ((close (position #\] glob :start (+ i 2))))
                        (vector-push-extend #\[ out)
                        (let ((start (1+ i)))
                          (when (char= (char glob start) #\!)
                            (vector-push-extend #\^ out)
                            (incf start))
                          (loop for k from start below close
                                do (let ((ch (char glob k)))
                                     (when (char= ch #\\)
                                       (vector-push-extend #\\ out))
                                     (vector-push-extend ch out))))
                        (vector-push-extend #\] out)
                        (setf i (1+ close))))
                     (t
                      (when (find c "\\.^$+()|{}[]")
                        (vector-push-extend #\\ out))
                      (vector-push-extend c out)
                      (incf i)))))
    ( coerce out 'simple-string)))

(defun file-name-nondirectory (path)
  (let ((slash (position #\/ path :from-end t)))
    (if slash (subseq path (1+ slash)) path)))

(defun directory-file-name (path)
  (if (and (> (length path) 1) (char= (char path (1- (length path))) #\/))
      (subseq path 0 (1- (length path)))
      path))

(defun ensure-trailing-slash (path)
  (if (and (plusp (length path)) (char= (char path (1- (length path))) #\/))
      path
      (concatenate 'string path "/")))

(defun relative-path (file dir)
  (let ((prefix (ensure-trailing-slash dir)))
    (if (and (>= (length file) (length prefix))
             (string= prefix file :end2 (length prefix)))
        (subseq file (length prefix))
        file)))

(defun make-glob-predicate (glob glob-dir)
  "Return a predicate on file paths matching GLOB under GLOB-DIR, or nil."
  (when (and glob (plusp (length glob)))
    (let ((matcher (compile-matcher (glob-to-regex glob) nil :anchored t))
          (has-slash (find #\/ glob))
          (dir (and glob-dir (ensure-trailing-slash glob-dir))))
      (if has-slash
          (lambda (file)
            (funcall matcher (if dir (relative-path file dir) file)))
          (lambda (file)
            (funcall matcher (file-name-nondirectory file)))))))

(defun searchable-directory-p (path)
  "Return true when directory PATH should be descended into."
  (let ((name (file-name-nondirectory (directory-file-name path))))
    (and (plusp (length name))
         (not (char= (char name 0) #\.))
         (not (member name *excluded-directories* :test #'string=)))))

(defun expand-search-entries (entries glob-predicate)
  "Expand any directory entries (ending in /) in ENTRIES in depth-first
lexicographical order, filtering discovered files by GLOB-PREDICATE."
  (let ((stack (copy-list entries))
        (files '()))
    (loop while stack
          do (checkpoint)
             (let ((next (pop stack)))
               (if (and (plusp (length next)) (char= (char next (1- (length next))) #\/))
                   (let* ((dir (directory-file-name next))
                          (names (sort (copy-list (lispm-kernel/files:directory-names dir)) #'string<)))
                     (dolist (name (nreverse names))
                       (unless (char= (char name 0) #\.)
                         (let* ((full (concatenate 'string dir "/" name))
                                (lstamp (lispm-kernel/files:file-stamp full :follow nil)))
                           (when lstamp
                             (case (lispm-kernel/files:stamp-kind lstamp)
                               (:directory
                                (when (searchable-directory-p full)
                                  (push (concatenate 'string full "/") stack)))
                               (:regular
                                (when (or (null glob-predicate) (funcall glob-predicate full))
                                  (push full stack)))
                               (:symlink
                                (let ((fstamp (lispm-kernel/files:file-stamp full :follow t)))
                                  (when (and fstamp (eq (lispm-kernel/files:stamp-kind fstamp) :regular))
                                    (when (or (null glob-predicate) (funcall glob-predicate full))
                                      (push full stack)))))))))))
                   (push next files))))
    (nreverse files)))

;;;; Scanning files in parallel

(defun truncate-line (line limit)
  "Truncate LINE to LIMIT characters, ending with U+2026 when truncated."
  (if (<= (length line) limit)
      line
      (concatenate 'string (subseq line 0 (max 0 (1- limit))) (string (code-char #x2026)))))

(defun search-file-octets (octets matcher max-matches)
  "Return up to MAX-MATCHES (LINE-NUMBER TEXT) matches in OCTETS."
  (declare (type (simple-array (unsigned-byte 8) (*)) octets))
  (let ((end (length octets))
        (pos 0)
        (line-number 1)
        (matches '())
        (count 0))
    (loop while (and (< pos end) (< count max-matches))
          do (let* ((newline (position 10 octets :start pos :end end))
                    (stop (or newline end))
                    (line (sb-ext:octets-to-string
                           octets :start pos :end stop
                           :external-format '(:utf-8 :replacement #\REPLACEMENT_CHARACTER))))
               (when (funcall matcher line)
                 (push (list line-number (truncate-line line 300)) matches)
                 (incf count))
               (if newline
                   (setf pos (1+ newline)
                         line-number (1+ line-number))
                   (return))))
    (nreverse matches)))

(defun scan-one-file (path matcher max-file-size max-matches)
  "Scan regular file PATH with MATCHER.
Return (:file PATH :matches ((LINE TEXT) ...)), :large, or nil."
  (checkpoint)
  (handler-case
      (lispm-kernel/files:with-regular-file (stream stamp path)
        (let* ((size (lispm-kernel/files:stamp-size stamp))
               (small (<= size max-file-size))
               (read-bytes (if small size (min size 8000)))
               (octets (lispm-kernel/files:read-range stream 0 read-bytes)))
          (when (and octets (not (position 0 octets :end (min (length octets) 8000))))
            (if (not small)
                (list :file path :large t)
                (let ((matches (search-file-octets octets matcher max-matches)))
                  (when matches
                    (list :file path :matches matches)))))))
    (error () nil)))

(define-job (search-files :class :cpu) (input)
  "Search local FILES for PATTERN in parallel across :cpu threads.
INPUT is (:files FILES :pattern PATTERN :case-fold BOOL :glob GLOB
:glob-dir DIR :open-files OPEN-FILES :max-file-size INT :max-matches INT)."
  (destructuring-bind (&key files pattern case-fold glob glob-dir open-files
                            (max-file-size (* 1024 1024)) (max-matches 200))
      input
    (check-type files list)
    (dolist (f files) (check-type f string))
    (check-type pattern string)
    (check-type glob (or null string))
    (check-type glob-dir (or null string))
    (check-type open-files list)
    (check-type max-file-size (integer 1))
    (check-type max-matches (integer 1))
    (let* ((matcher (compile-matcher pattern case-fold))
           (glob-pred (make-glob-predicate glob glob-dir))
           (all-files (expand-search-entries files glob-pred))
           (open-set (let ((table (make-hash-table :test #'equal)))
                       (dolist (f open-files table)
                         (setf (gethash f table) t))))
           (scanned (parallel-map
                     (lambda (file)
                       (if (gethash file open-set)
                           (list :file file :open t)
                           (scan-one-file file matcher max-file-size max-matches)))
                     all-files
                     :threads 4))
           (items '())
           (large 0))
      (dolist (entry scanned)
        (when (consp entry)
          (when (getf entry :large)
            (incf large))
          (push entry items)))
      (list :items (nreverse items) :large large))))
