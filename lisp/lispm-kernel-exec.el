;;; lispm-kernel-exec.el --- Programs run in the kernel, not in Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-kernel
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is not part of GNU Emacs.

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

;;; Commentary:

;; A program Emacs runs, it forks itself to start, and reads what it
;; prints on its own thread; one it waits for, as with `call-process' or
;; `process-lines', freezes it until it exits: ps listing a thousand
;; processes, git describing a checkout.  The kernel's `exec' job runs
;; the program in the kernel instead, and Emacs hears how it went:
;;
;;   (lispm-kernel-exec "git" '("rev-parse" "HEAD")
;;                      (lambda (exit output errors) ...))
;;
;; The callback gets the program's exit code, or a sentence saying why it
;; did not run or exit, then what it printed to its standard output and
;; its standard error.  The program is found in `exec-path' and runs in
;; `default-directory' with `process-environment', as `call-process'
;; would run it.  Where no kernel that knows the job runs, or the program
;; or directory is not on this computer, Emacs runs it itself, in the
;; background, `lispm-kernel-exec-locally'.  The kernel is the one
;; `lispm-kernel-exec-runtime-function' returns, by default the desktop's.
;;
;; LispM runs its programs through `lispm-exec', lispm-agent's
;; (lispm-exec.el), which does not know the kernel:
;; `lispm-kernel-exec-mode' has it run them here, advising its
;; `lispm-exec-function', and turned off, gives them back.

;;; Code:

(require 'cl-lib)
(require 'lispm-kernel)

(defvar lispm-kernel-sessions-mode)
(defvar lispm-kernel-exec-mode)
(defvar lispm-exec-function)
(declare-function lispm-kernel-desktop-runtime "lispm-kernel-desktop" ())

(defcustom lispm-kernel-exec-timeout 300
  "Seconds a program the kernel runs may take before it is stopped.
Nil lets it run for ever."
  :type '(choice (const :tag "Never" nil) integer) :group 'lispm-kernel)

(defvar lispm-kernel-exec-runtime-function #'lispm-kernel-exec--sessions-runtime
  "Function returning the runtime whose kernel runs programs, or nil for none.")

(defconst lispm-kernel-exec--owner 4
  "The owner of the kernel's requests for programs, after package.el's.")

(defun lispm-kernel-exec--sessions-runtime ()
  "Return the agents' kernel while `lispm-kernel-sessions-mode' runs it."
  (and (bound-and-true-p lispm-kernel-sessions-mode)
       (fboundp 'lispm-kernel-desktop-runtime)
       (lispm-kernel-desktop-runtime)))

(defun lispm-kernel-exec--runtime (&optional job)
  "Return a runtime whose kernel runs and knows JOB (by default `:exec'), or nil."
  (when-let* ((runtime (and lispm-kernel-exec-runtime-function
                            (funcall lispm-kernel-exec-runtime-function))))
    (and (lispm-kernel-live-p runtime)
         (memq (or job :exec) (plist-get (lispm-kernel-runtime-hello runtime) :jobs))
         runtime)))

(defun lispm-kernel-exec--environment (directory)
  "Return the environment Emacs gives a program it runs in DIRECTORY:
`process-environment', an entry before another of its name hiding it, a
name alone removing it, and PWD, DIRECTORY."
  (let ((seen (make-hash-table :test #'equal))
        (entries (list (concat "PWD=" (directory-file-name directory)))))
    (puthash "PWD" t seen)
    (dolist (entry process-environment)
      (let* ((equals (string-search "=" entry))
             (name (if equals (substring entry 0 equals) entry)))
        (unless (gethash name seen)
          (puthash name t seen)
          (when equals (push entry entries)))))
    (nreverse entries)))

(defun lispm-kernel-exec--call (callback &rest arguments)
  "Call CALLBACK with ARGUMENTS, saying what error it signals."
  (with-demoted-errors "lispm-kernel-exec: %S"
    (apply callback arguments)))

;;;; In Emacs

(cl-defun lispm-kernel-exec-locally (program args callback &key input timeout on-output combine-error)
  "Run PROGRAM with ARGS as a process of Emacs's own, in the background.
CALLBACK, ARGS, INPUT, TIMEOUT, ON-OUTPUT and COMBINE-ERROR are as
`lispm-kernel-exec' has them."
  (let ((output (generate-new-buffer " *lispm-kernel-exec*" t))
        (errors (unless combine-error (generate-new-buffer " *lispm-kernel-exec errors*" t)))
        stderr timer)
    (condition-case err
        (let ((process
               (make-process
                :name program :buffer output :command (cons program args)
                :connection-type 'pipe :noquery t :coding 'utf-8
                :stderr (and errors
                             (setq stderr (make-pipe-process :name (concat program " errors") :buffer errors
                                                             :noquery t :coding 'utf-8 :sentinel #'ignore)))
                :filter (and on-output
                             (lambda (proc chunk)
                               (when (buffer-live-p (process-buffer proc))
                                 (with-current-buffer (process-buffer proc)
                                   (goto-char (point-max))
                                   (insert chunk)))
                               (lispm-kernel-exec--call on-output chunk)))
                :sentinel
                (lambda (process _event)
                  (when (and (not (process-live-p process)) (buffer-live-p output))
                    (when timer (cancel-timer timer))
                    (when stderr
                      ;; What it said last, read before its pipe goes.
                      (while (accept-process-output stderr 0 nil t))
                      (delete-process stderr))
                    (let ((exit (cond ((process-get process 'timed-out)
                                       (format "%s did not finish in %ss" program timeout))
                                      ((eq (process-status process) 'exit)
                                       (process-exit-status process))
                                      (t (format "%s ended by signal %s" program (process-exit-status process)))))
                          (printed (with-current-buffer output (buffer-string)))
                          (said (if errors (with-current-buffer errors (buffer-string)) "")))
                      (kill-buffer output)
                      (when errors (kill-buffer errors))
                      (lispm-kernel-exec--call callback exit printed said)))))))
          (when timeout
            (setq timer
                  (run-at-time timeout nil
                               (lambda ()
                                 (when (process-live-p process)
                                   (process-put process 'timed-out t)
                                   (ignore-errors (kill-process process)))))))
          ;; A program may be gone before it is sent its input, or the
          ;; end of it, as one reading none, as diff, may be: its
          ;; sentinel then says how it went, later.
          (ignore-errors
            (when input
              (process-send-string process input))
            (process-send-eof process)))
      (error (when timer (cancel-timer timer))
             (when (process-live-p stderr) (delete-process stderr))
             (kill-buffer output)
             (when errors (kill-buffer errors))
             ;; Never before the caller has its answer back.
             (run-at-time 0 nil #'lispm-kernel-exec--call callback (error-message-string err) "" "")))
    nil))

;;;; In the kernel

(defun lispm-kernel-exec--finish (program callback status value output)
  "Give CALLBACK how the kernel's request to run PROGRAM ended, STATUS
and VALUE, OUTPUT what it printed meanwhile."
  (pcase (cons status value)
    (`(success . (:exit ,code :stderr ,said))
     (lispm-kernel-exec--call callback code output said))
    (`(success . (:signal ,signal :stderr ,said))
     (lispm-kernel-exec--call callback (format "%s ended by signal %s" program signal) output said))
    (`(failed . ,why)
     (lispm-kernel-exec--call callback (format "%s" why) output ""))
    (_ (lispm-kernel-exec--call callback (format "%s: %s" program (if value (list status value) status))
                                output ""))))

(cl-defun lispm-kernel-exec--submit (program args callback fallback
                                     &key input timeout on-output combine-error)
  "Have the kernel run PROGRAM with ARGS, then call CALLBACK; return
a zero-argument cancellation function when it took it, nil when it
cannot: no kernel knowing the job, the program not found, or a directory
not on this computer.  A kernel that turns the request away later, as
when full, leaves it to FALLBACK, called as `lispm-kernel-exec' is,
where the program was asked for."
  (when-let* ((runtime (lispm-kernel-exec--runtime))
              ((not (file-remote-p default-directory)))
              (directory (expand-file-name default-directory))
              ((file-directory-p directory))
              (file (executable-find program))
              ((file-name-absolute-p file)))
    (let ((environment process-environment)
          (effective-timeout (or timeout lispm-kernel-exec-timeout))
          (chunks nil)
          (aborted nil)
          id)
      (condition-case nil
          (progn
            (setq id
                  (lispm-kernel-submit
                   runtime 'exec
                   (list :program (expand-file-name file) :args args :cwd (directory-file-name directory)
                         :env (lispm-kernel-exec--environment directory) :stdin input
                         :timeout effective-timeout
                         :combine-error (and combine-error t))
                   :owner lispm-kernel-exec--owner
                   ;; The kernel stops the program first, and says so.
                   :timeout (and effective-timeout (+ effective-timeout 10))
                   :on-result
                   (lambda (kind value)
                     (unless aborted
                       (pcase kind
                         ('chunk
                          (push value chunks)
                          (when on-output
                            (lispm-kernel-exec--call on-output value)))
                         ('rejected
                          (let ((default-directory directory)
                                (process-environment environment)
                                (keys nil))
                            (when combine-error (setq keys (plist-put keys :combine-error combine-error)))
                            (when on-output (setq keys (plist-put keys :on-output on-output)))
                            (when timeout (setq keys (plist-put keys :timeout timeout)))
                            (when input (setq keys (plist-put keys :input input)))
                            (apply fallback program args callback keys)))
                         (_ (lispm-kernel-exec--finish program callback kind value
                                                       (apply #'concat (nreverse chunks)))))))))
            (lambda ()
              (setq aborted t)
              (lispm-kernel-cancel runtime id)))
        ;; The kernel went away meanwhile, or ARGS cannot go to it.
        (error nil)))))

;;;###autoload
(cl-defun lispm-kernel-exec (program args callback &key input timeout on-output combine-error)
  "Run PROGRAM with ARGS in the kernel, then call CALLBACK with how it went.
CALLBACK gets the exit code, an integer, or a string saying why PROGRAM
did not run or exit, then what it printed to its standard output and its
standard error, strings read as UTF-8; it is called later, never before
this returns.  PROGRAM is found in `exec-path' and runs in
`default-directory' with `process-environment', reading INPUT, a string,
when given, else nothing.  ARGS are strings.  Where no kernel knowing
the `exec' job runs, see `lispm-kernel-exec-runtime-function', or
PROGRAM or `default-directory' is not on this computer, Emacs runs it,
`lispm-kernel-exec-locally'.  The kernel stops a program that takes longer
than TIMEOUT (by default `lispm-kernel-exec-timeout')."
  (unless (lispm-kernel-exec--submit program args callback #'lispm-kernel-exec-locally
                                     :input input :timeout timeout
                                     :on-output on-output :combine-error combine-error)
    (lispm-kernel-exec-locally program args callback
                               :input input :timeout timeout
                               :on-output on-output :combine-error combine-error))
  nil)

;;;; HTTP streaming and parallel file search in the kernel

(cl-defun lispm-kernel-http-stream (url headers body on-chunk on-finish &key curl fallback)
  "POST BODY to URL with HEADERS in the kernel's `http-stream' job.
ON-CHUNK is called with each UTF-8 text chunk as it arrives; ON-FINISH
is called once at the end with the complete output (or stderr if output
is empty).  When the kernel rejects the request for capacity and
FALLBACK is given, call FALLBACK with no arguments.  Return a
zero-argument cancellation function when the kernel took the request, or
nil when it cannot."
  (when-let* ((runtime (lispm-kernel-exec--runtime :http-stream)))
    (let ((chunks nil)
          (aborted nil)
          (fallback-proc nil)
          id)
      (condition-case nil
          (progn
            (setq id
                  (lispm-kernel-submit
                   runtime 'http-stream
                   (list :url url :headers headers :body body
                         :curl (or (and curl (executable-find curl)) curl "curl")
                         :env (lispm-kernel-exec--environment
                               (if (file-remote-p default-directory)
                                   temporary-file-directory
                                 (expand-file-name default-directory))))
                   :owner lispm-kernel-exec--owner
                   :timeout 920
                   :on-result
                   (lambda (kind value)
                     (unless aborted
                       (pcase kind
                         ('chunk
                          (push value chunks)
                          (when on-chunk
                            (lispm-kernel-exec--call on-chunk value)))
                         ((and 'rejected (guard fallback))
                          (setq fallback-proc (funcall fallback)))
                         ('success
                          (let ((output (apply #'concat (nreverse chunks)))
                                (stderr (plist-get value :stderr)))
                            (lispm-kernel-exec--call
                             on-finish
                             (if (and (string-empty-p output) (stringp stderr))
                                 stderr
                               output))))
                         (_
                          (let ((output (apply #'concat (nreverse chunks))))
                            (lispm-kernel-exec--call
                             on-finish
                             (if (string-empty-p output)
                                 (format "http-stream %s: %s" kind (or value ""))
                               output)))))))))
            (lambda ()
              (setq aborted t)
              (if (processp fallback-proc)
                  (progn
                    (process-put fallback-proc 'lispm-aborted t)
                    (ignore-errors (delete-process fallback-proc)))
                (lispm-kernel-cancel runtime id))))
        (error nil)))))

(cl-defun lispm-kernel-search-files (files pattern case-fold callback
                                     &key glob glob-dir open-files
                                     max-file-size max-matches)
  "Search local FILES for PATTERN in the kernel's `search-files' job.
Call CALLBACK with (:items ITEMS :large LARGE) on success, or (:error WHY)
if the job fails or is rejected.  Return a zero-argument cancellation
function when the kernel took the request, or nil when it cannot."
  (when-let* ((runtime (lispm-kernel-exec--runtime :search-files))
              ((cl-every (lambda (f) (and (stringp f) (not (file-remote-p f)))) files)))
    (let ((aborted nil)
          id)
      (condition-case nil
          (progn
            (setq id
                  (lispm-kernel-submit
                   runtime 'search-files
                   (list :files files
                         :pattern pattern
                         :case-fold (and case-fold t)
                         :glob glob
                         :glob-dir glob-dir
                         :open-files open-files
                         :max-file-size (or max-file-size 1048576)
                         :max-matches (or max-matches 200))
                   :owner lispm-kernel-exec--owner
                   :timeout 120
                   :on-result
                   (lambda (kind value)
                     (unless aborted
                       (pcase kind
                         ('chunk nil)
                         ('success (lispm-kernel-exec--call callback value))
                         (_ (lispm-kernel-exec--call callback (list :error (or value kind)))))))))
            (lambda ()
              (setq aborted t)
              (lispm-kernel-cancel runtime id)))
        (error nil)))))

;;;; lispm-agent's programs

(defun lispm-kernel-exec--around (original program args callback &rest keys)
  "Run PROGRAM with ARGS in the kernel, else as ORIGINAL would, a
`lispm-exec-function' that CALLBACK and KEYS are for."
  (or (apply #'lispm-kernel-exec--submit program args callback original keys)
      (apply original program args callback keys)))

(defun lispm-kernel-exec--hook ()
  "Advise `lispm-exec-function' while the mode is on and it is there."
  (when (and lispm-kernel-exec-mode (boundp 'lispm-exec-function))
    (add-function :around lispm-exec-function #'lispm-kernel-exec--around)))

;;;###autoload
(define-minor-mode lispm-kernel-exec-mode
  "Have the kernel run the programs LispM runs in the background.
LispM runs them through `lispm-exec', which the mode advises: the kernel
`lispm-kernel-exec-runtime-function' returns, by default the agents'
while `lispm-kernel-sessions-mode' runs it, runs them; while none that
knows the `exec' job runs, `lispm-exec' runs them as without the mode."
  :global t :group 'lispm-kernel
  (if lispm-kernel-exec-mode
      (if (boundp 'lispm-exec-function)
          (lispm-kernel-exec--hook)
        (with-eval-after-load 'lispm-exec (lispm-kernel-exec--hook)))
    (when (boundp 'lispm-exec-function)
      (remove-function lispm-exec-function #'lispm-kernel-exec--around))))

(defun lispm-kernel-exec-unload-function ()
  "Give `lispm-exec' its programs back before `unload-feature' runs."
  (when lispm-kernel-exec-mode (lispm-kernel-exec-mode -1))
  nil)

(provide 'lispm-kernel-exec)
;;; lispm-kernel-exec.el ends here
