;;;; search-test.lisp --- Tests of the kernel's parallel file search

;; Copyright (C) 2026  Ryan.K
;; SPDX-License-Identifier: AGPL-3.0-or-later

(in-package #:lispm-kernel/test)

(defun search-line (id files pattern &rest keys)
  (message-string `(submit ,id search-files (:files ,files :pattern ,pattern ,@keys))))

(deftest search-regex-features ()
  (let ((match (lambda (pat line &optional case-fold)
                 (funcall (lispm-kernel::compile-matcher pat case-fold) line))))
    (is (funcall match "\\(defun lispm-demo-(a|b)\\b" "(defun lispm-demo-a ()"))
    (is (funcall match "\\(defun lispm-demo-(a|b)\\b" "(defun lispm-demo-b ()"))
    (is (not (funcall match "\\(defun lispm-demo-(a|b)\\b" "(defun lispm-demo-ab ()")))
    (is (not (funcall match "\\(defun lispm-demo-(a|b)\\b" "(defun lispm-demo-c ()")))
    (is (funcall match "lispm-demo-\\w+" "(defun lispm-demo-notes ()"))
    (is (funcall match "DOC" "  \"Doc.\")" t))
    (is (not (funcall match "DOC" "  \"Doc.\")" nil)))
    (is (funcall match "^;; header$" ";; header"))
    (is (not (funcall match "^;; header$" " ;; header")))
    (is (funcall match "x{2,3}" "axxb"))
    (is (not (funcall match "x{2,3}" "axb")))
    (is (funcall match "(foo)\\s+\\1" "foo   foo"))
    (is (not (funcall match "(foo)\\s+\\1" "foo   bar")))
    (signals error (lispm-kernel::compile-matcher "a(?=b)" nil))
    (signals error (lispm-kernel::compile-matcher "abc\\" nil))))

(deftest search-files-parallel-and-globs ()
  (with-directory (directory)
    (write-file (path directory "a.el")
                ";; header"
                "(defun lispm-demo-a ()"
                "  \"Doc.\")")
    (write-file (path directory "sub" "b.el")
                ";; header"
                "(defun lispm-demo-b ()"
                "  \"Doc.\")")
    (write-file (path directory "notes.txt")
                ";; header"
                "(defun lispm-demo-notes ()"
                "  \"Doc.\")")
    (write-file (path directory ".hidden" "c.el")
                ";; header"
                "(defun lispm-demo-c ()"
                "  \"Doc.\")")
    (write-octets (path directory "blob.bin")
                  (concatenate '(vector (unsigned-byte 8))
                               (octets "(defun lispm-demo-blob")
                               #(0 0 0)))
    (with-kernel (kernel collector)
      ;; Directory expansion, skipping .hidden and binary files.
      (send kernel (search-line 1 (list (concatenate 'string directory "/"))
                                "\\(defun lispm-demo-(a|b)\\b"))
      (let ((result (fourth (done-of 1 (answered collector 1)))))
        (is (equal `(:items ((:file ,(path directory "a.el")
                              :matches ((2 "(defun lispm-demo-a ()")))
                             (:file ,(path directory "sub" "b.el")
                              :matches ((2 "(defun lispm-demo-b ()"))))
                     :large 0)
                   result)))
      ;; Glob filtering (*.txt) and open-files passthrough.
      (send kernel (search-line 2 (list (concatenate 'string directory "/"))
                                "lispm-demo-\\w+"
                                :glob "*.txt"
                                :glob-dir directory))
      (let ((result (fourth (done-of 2 (answered collector 2)))))
        (is (equal `(:items ((:file ,(path directory "notes.txt")
                              :matches ((2 "(defun lispm-demo-notes ()"))))
                     :large 0)
                   result)))
      ;; Open files are preserved in order as (:file PATH :open t) so Emacs searches unsaved buffers.
      (send kernel (search-line 3 (list (path directory "a.el") (path directory "sub" "b.el"))
                                "lispm-demo-\\w+"
                                :open-files (list (path directory "a.el"))))
      (let ((result (fourth (done-of 3 (answered collector 3)))))
        (is (equal `(:items ((:file ,(path directory "a.el") :open t)
                             (:file ,(path directory "sub" "b.el")
                              :matches ((2 "(defun lispm-demo-b ()"))))
                     :large 0)
                   result)))
      ;; Large non-binary files are counted in :large; large binary files are ignored.
      (send kernel (search-line 4 (list (path directory "a.el") (path directory "blob.bin"))
                                "lispm-demo"
                                :max-file-size 10))
      (let ((result (fourth (done-of 4 (answered collector 4)))))
        (is (equal `(:items ((:file ,(path directory "a.el") :large t)) :large 1)
                   result))))))
