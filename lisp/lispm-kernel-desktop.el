;;; lispm-kernel-desktop.el --- Opt-in desktop session acceleration -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later
;;; Commentary:
;; This integration lives with kernel so the existing desktop remains untouched.
;; Enable only after building/loading a compatible module. Existing terminal
;; behavior and third-party providers are unchanged. Builtin session providers
;; return the last snapshot while a native refresh runs in the background.
;;; Code:
(require 'lispm-kernel-sessions)
(require 'lispm-kernel-broker)
(defvar lispm-desktop-agent-codex-sessions-directory)
(defvar lispm-desktop-agent-claude-projects-directory)
(declare-function lispm-desktop-sidebar-refresh-list "ext:lispm-desktop-sidebar" (kind))
(defcustom lispm-kernel-desktop-module nil
  "Explicit path to the built lispm-kernel Emacs module."
  :type '(choice (const nil) file) :group 'lispm-kernel)
(defcustom lispm-kernel-desktop-cache-seconds 2
  "Maximum snapshot age before a provider schedules a background refresh."
  :type 'number :group 'lispm-kernel)
(defvar lispm-kernel-desktop--runtime nil)
(defvar lispm-kernel-desktop--cache (make-hash-table :test #'eq))
(defvar lispm-kernel-desktop--refresh-timer nil)
(defvar lispm-kernel-desktop-last-error nil)
(defvar lispm-kernel-desktop-mode nil)

(defun lispm-kernel-desktop--repaint ()
  "Coalesce completion repaint without retriggering explicit refresh advice."
  (unless lispm-kernel-desktop--refresh-timer
    (setq lispm-kernel-desktop--refresh-timer
          (run-with-idle-timer 0.05 nil
                               (lambda ()
                                 (setq lispm-kernel-desktop--refresh-timer nil)
                                 (when (and lispm-kernel-desktop-mode
                                            (fboundp 'lispm-desktop-sidebar-refresh-list)
                                            (get-buffer-window "*Agents*" 'visible))
                                   (lispm-desktop-sidebar-refresh-list 'agents)))))))

(defun lispm-kernel-desktop--provider (agent original &rest args)
  "Use a bounded asynchronous native snapshot for AGENT, else ORIGINAL ARGS."
  (let* ((root (pcase agent
                 ('codex (bound-and-true-p lispm-desktop-agent-codex-sessions-directory))
                 ('claude (bound-and-true-p lispm-desktop-agent-claude-projects-directory))))
         (owner (if (eq agent 'codex) 1 2)))
    (if (or (not lispm-kernel-desktop-mode) (null lispm-kernel-desktop--runtime)
            (not root) (file-remote-p root) (not (file-directory-p root)))
        (apply original args)
      (let* ((entry (gethash agent lispm-kernel-desktop--cache))
             (generation (or (plist-get entry :generation) 0)))
        (when (and entry (not (equal root (plist-get entry :root))))
          (when-let* ((timer (plist-get entry :retry-timer))) (cancel-timer timer))
          (setq generation (1+ generation) entry (list :root root :generation generation))
          (lispm-kernel-supersede lispm-kernel-desktop--runtime owner generation)
          (puthash agent entry lispm-kernel-desktop--cache))
        (when (and (not (plist-get entry :request))
                   (or (null (plist-get entry :time))
                       (> (- (float-time) (plist-get entry :time))
                          lispm-kernel-desktop-cache-seconds)))
          (let ((request
                 (lispm-kernel-scan-sessions
                  lispm-kernel-desktop--runtime agent root
                  (lambda (sessions summary)
                    (when (and lispm-kernel-desktop-mode
                               (= generation (or (plist-get (gethash agent lispm-kernel-desktop--cache) :generation) 0)))
                      (let ((current (gethash agent lispm-kernel-desktop--cache)))
                        (when (plist-get summary :error)
                          (setq lispm-kernel-desktop-last-error summary))
                        (puthash agent
                                 (list :sessions (if (plist-get summary :error)
                                                     (plist-get current :sessions) sessions)
                                       :time (float-time) :generation generation :root root)
                                 lispm-kernel-desktop--cache)
                        (lispm-kernel-desktop--repaint))))
                  :owner owner :generation generation :fallback (lambda () (apply original args)))))
            (cond
             ((integerp request)
              (setq entry (plist-put (plist-put entry :root root) :request request))
              (puthash agent entry lispm-kernel-desktop--cache))
             ((memq request '(busy capacity))
              ;; Admission contention must not leave an empty sidebar stuck.
              ;; One bounded retry timer per provider; no synchronous retry loop.
              (setq entry (plist-put (plist-put entry :root root) :request 'retry))
              (setq entry
                    (plist-put entry :retry-timer
                               (run-at-time 0.05 nil
                                            (lambda ()
                                              (when (and lispm-kernel-desktop-mode
                                                         (= generation (or (plist-get (gethash agent lispm-kernel-desktop--cache) :generation) 0)))
                                                (let ((current (gethash agent lispm-kernel-desktop--cache)))
                                                  (setq current (plist-put (plist-put current :request nil) :retry-timer nil))
                                                  (puthash agent current lispm-kernel-desktop--cache)
                                                  (apply #'lispm-kernel-desktop--provider agent original args)))))))
              (puthash agent entry lispm-kernel-desktop--cache))
             (t (setq lispm-kernel-desktop-last-error request)))))
        (copy-sequence (plist-get (gethash agent lispm-kernel-desktop--cache) :sessions))))))

(defun lispm-kernel-desktop--codex (original &rest args)
  (apply #'lispm-kernel-desktop--provider 'codex original args))
(defun lispm-kernel-desktop--claude (original &rest args)
  (apply #'lispm-kernel-desktop--provider 'claude original args))
(defun lispm-kernel-desktop-invalidate (&rest _)
  "Invalidate snapshots and supersede active native scans before manual refresh."
  (when lispm-kernel-desktop--runtime
    (dolist (agent '(codex claude))
      (let* ((entry (gethash agent lispm-kernel-desktop--cache))
             (generation (1+ (or (plist-get entry :generation) 0))))
        (when-let* ((timer (plist-get entry :retry-timer))) (cancel-timer timer))
        (lispm-kernel-supersede lispm-kernel-desktop--runtime (if (eq agent 'codex) 1 2) generation)
        (puthash agent (list :sessions (plist-get entry :sessions) :generation generation :root (plist-get entry :root))
                 lispm-kernel-desktop--cache)))))

(define-minor-mode lispm-kernel-desktop-mode
  "Use native background discovery for built-in desktop session providers.
Missing/incompatible modules leave the existing Elisp providers active."
  :global t :group 'lispm-kernel
  (if lispm-kernel-desktop-mode
      (progn
        (require 'lispm-desktop-agent-codex)
        (require 'lispm-desktop-agent-claude)
        (unless lispm-kernel-desktop--runtime
          (setq lispm-kernel-desktop--runtime
                (and (or (featurep 'lispm-kernel-module) lispm-kernel-desktop-module)
                     (lispm-kernel-try-create lispm-kernel-desktop-module))))
        (unless lispm-kernel-desktop--runtime
          (setq lispm-kernel-desktop-last-error (or lispm-kernel-module-error 'module-unavailable)))
        (when lispm-kernel-desktop--runtime
          (unless (eq lispm-kernel-broker--runtime lispm-kernel-desktop--runtime)
            (lispm-kernel-broker-start lispm-kernel-desktop--runtime)))
        (advice-add 'lispm-desktop-agent-codex-sessions :around #'lispm-kernel-desktop--codex)
        (advice-add 'lispm-desktop-agent-claude-sessions :around #'lispm-kernel-desktop--claude)
        (advice-add 'lispm-desktop-agent-list-refresh :before #'lispm-kernel-desktop-invalidate))
    (lispm-kernel-broker-stop)
    (advice-remove 'lispm-desktop-agent-codex-sessions #'lispm-kernel-desktop--codex)
    (advice-remove 'lispm-desktop-agent-claude-sessions #'lispm-kernel-desktop--claude)
    (advice-remove 'lispm-desktop-agent-list-refresh #'lispm-kernel-desktop-invalidate)
    (when lispm-kernel-desktop--runtime (lispm-kernel-shutdown lispm-kernel-desktop--runtime))
    (setq lispm-kernel-desktop--runtime nil)
    (when lispm-kernel-desktop--refresh-timer (cancel-timer lispm-kernel-desktop--refresh-timer))
    (setq lispm-kernel-desktop--refresh-timer nil)
    (maphash (lambda (_ entry)
               (when-let* ((timer (plist-get entry :retry-timer))) (cancel-timer timer)))
             lispm-kernel-desktop--cache)
    (clrhash lispm-kernel-desktop--cache)))

(provide 'lispm-kernel-desktop)
;;; lispm-kernel-desktop.el ends here
