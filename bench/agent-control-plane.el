;;; agent-control-plane.el --- Benchmark multi-agent turns and control plane -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Ryan.K

;; Author: Ryan.K
;; URL: https://github.com/LispMachineLab/lispm-kernel
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
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

;; Multi-agent concurrency benchmark comparing three execution paths in `lispm-agent':
;;
;;   elisp          Pure Elisp HTTP (curl), Elisp SSE decode, and Elisp tools.
;;   kernel-sse     `lispm-kernel' offloaded `llm-stream' + tools, Elisp turn loop.
;;   kernel-actors  Full `lispm-kernel' `P_agents' actor loop + `lispm-control-plane'.
;;
;; Run through `scripts/bench-agents.py' (or `make bench-agents').
;; The JSON report is printed on the line immediately following `BENCH-JSON'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'lispm-kernel)
(require 'lispm-kernel-exec)

;; External variables and functions from `lispm-agent'.  Declared here so
;; this file byte-compiles cleanly even against minimal `lispm-agent' builds
;; without loading optional package dependencies at compile time.
(defvar package-user-dir)
(defvar lispm-directory)
(defvar lispm-agents-state-file)
(defvar lispm-agents-opened-times)
(defvar lispm-agents--archived)
(defvar lispm--agents)
(defvar lispm-git)
(defvar lispm-auto-title)
(defvar lispm-sandbox-level)
(defvar lispm-auto-approve-all)
(defvar lispm-tool-action-functions)
(defvar lispm-backends)
(defvar lispm-backend)
(defvar lispm-api-function)
(defvar lispm-api-kernel-sse-decode)
(defvar lispm-control-plane-mode)
(defvar lispm-control-plane-runtime-function)
(defvar lispm-max-steps)

(declare-function package-initialize "package" (&optional no-activate))
(declare-function lispm-api-stream "lispm-api" (backend request &key on-delta on-done on-error))
(declare-function lispm-register-agent "lispm-core" (name &rest props))
(declare-function lispm-tell "lispm-turns" (agent text &rest args))
(declare-function lispm-agent-id "lispm-core" (agent))
(declare-function lispm-agent-buffer "lispm-core" (agent))
(declare-function lispm-agent-state "lispm-core" (agent))
(declare-function lispm-unwatch "lispm-turns" (agent))
(declare-function lispm-job-cancel-all "lispm-job" ())
(declare-function lispm-control-plane-reset "lispm-control-plane" ())

(defvar lispm-kernel-agent-bench--interval 0.002
  "Seconds between event-loop responsiveness probe ticks.")

(defvar lispm-kernel-agent-bench--samples nil
  "Measured timer lateness samples in milliseconds.")

(defvar lispm-kernel-agent-bench--timer nil
  "Active repeating probe timer during a benchmark run.")

(defvar lispm-kernel-agent-bench--frames 0
  "Count of wire frames handled by `lispm-kernel--handle' during a run.")

(defun lispm-kernel-agent-bench--percentile (values fraction)
  "Return the FRACTION quantile of numeric VALUES, or 0.0 when empty."
  (if (null values)
      0.0
    (let* ((sorted (sort (copy-sequence values) #'<))
           (idx (min (1- (length sorted))
                     (floor (* fraction (length sorted))))))
      (float (nth idx sorted)))))

(defun lispm-kernel-agent-bench--start-probe ()
  "Start the high-resolution event-loop lateness probe timer."
  (setq lispm-kernel-agent-bench--samples nil)
  (let ((last (float-time))
        (interval lispm-kernel-agent-bench--interval))
    (setq lispm-kernel-agent-bench--timer
          (run-at-time interval interval
                       (lambda ()
                         (let ((now (float-time)))
                           (push (max 0.0 (* 1000.0 (- now last interval)))
                                 lispm-kernel-agent-bench--samples)
                           (setq last now)))))))

(defun lispm-kernel-agent-bench--stop-probe ()
  "Stop the probe timer and return summary statistics plist."
  (when lispm-kernel-agent-bench--timer
    (cancel-timer lispm-kernel-agent-bench--timer)
    (setq lispm-kernel-agent-bench--timer nil))
  (let* ((values (nreverse lispm-kernel-agent-bench--samples))
         (stalls (cl-count-if (lambda (v) (> v 16.0)) values)))
    (setq lispm-kernel-agent-bench--samples nil)
    (list :samples (length values)
          :stalls-over-16ms stalls
          :p50 (lispm-kernel-agent-bench--percentile values 0.50)
          :p95 (lispm-kernel-agent-bench--percentile values 0.95)
          :p99 (lispm-kernel-agent-bench--percentile values 0.99)
          :max (if values (float (apply #'max values)) 0.0))))

(defun lispm-kernel-agent-bench--await-ready (rt)
  "Wait until kernel runtime RT completes its handshake and echoes ping."
  (let ((done nil)
        (deadline (+ (float-time) 10.0)))
    (lispm-kernel-ping rt (lambda (&rest _) (setq done t)))
    (while (and (not done) (< (float-time) deadline))
      (accept-process-output nil 0.01)
      (lispm-kernel-dispatch rt))
    (unless (and done (lispm-kernel-live-p rt))
      (error "Kernel runtime failed handshake within 10s"))))

(defun lispm-kernel-agent-bench--query-stats (rt)
  "Synchronously query stats plist from live kernel runtime RT, or nil."
  (when (and rt (lispm-kernel-live-p rt))
    (let ((done nil)
          (stats nil)
          (deadline (+ (float-time) 5.0)))
      (lispm-kernel-stats rt (lambda (s) (setq stats s done t)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.01)
        (lispm-kernel-dispatch rt))
      stats)))

(defun lispm-kernel-agent-bench--verify-agents (agents bufs replies)
  "Assert all AGENTS in BUFS completed cleanly with REPLIES."
  (let ((count (length agents)))
    (dotimes (i count)
      (let* ((ag (nth i agents))
             (buf (nth i bufs))
             (reply (aref replies i))
             (transcript (when (buffer-live-p (lispm-agent-buffer ag))
                           (with-current-buffer (lispm-agent-buffer ag)
                             (buffer-string))))
             (buf-text (when (buffer-live-p buf)
                         (with-current-buffer buf (buffer-string)))))
        (unless (eq (lispm-agent-state ag) 'idle)
          (error "Agent %d (%s) not idle: %S" i (lispm-agent-id ag) (lispm-agent-state ag)))
        (unless (and (stringp reply) (string-search "agent-bench-complete" reply))
          (error "Agent %d missing completion reply: %S" i reply))
        (dolist (pat '("\\*\\* DONE run_shell"
                       "\\*\\* DONE search_files"
                       "\\*\\* DONE read_file"
                       "\\*\\* DONE edit_buffer"))
          (unless (and transcript (string-match-p pat transcript))
            (error "Agent %d transcript missing %s" i pat)))
        (unless (and buf-text
                     (string-search "NEW" buf-text)
                     (not (string-search "OLD" buf-text)))
          (error "Buffer %s was not edited properly: %S" (buffer-name buf) buf-text))))))

(defun lispm-kernel-agent-bench--run-once (mode count url workspace)
  "Execute one benchmark trial for MODE with COUNT agents against URL in WORKSPACE."
  (let* ((tmp (file-name-as-directory (make-temp-file "lispm-agent-bench-" t)))
         (program (or (getenv "LISPM_KERNEL_PROGRAM")
                      (expand-file-name "build/lispm-kernel")))
         (rt (unless (string= mode "elisp") (lispm-kernel-start program)))
         (target-bufs nil)
         (view-bufs nil)
         (agents nil)
         (replies (make-vector count nil))
         (frame-counter (lambda (&rest _) (cl-incf lispm-kernel-agent-bench--frames)))
         (orig-runtime-fn (symbol-function 'lispm-kernel-exec--runtime))
         (prev-exec-mode (and (boundp 'lispm-kernel-exec-mode) lispm-kernel-exec-mode)))
    (setq lispm-kernel-agent-bench--frames 0)
    (when rt (lispm-kernel-agent-bench--await-ready rt))
    (unwind-protect
        (let* ((lispm-directory (expand-file-name "home/" tmp))
               (lispm-agents-state-file (expand-file-name "agent-sessions.eld" tmp))
               (lispm-agents-opened-times nil)
               (lispm-agents--archived 'unloaded)
               (lispm--agents nil)
               (lispm-git nil)
               (lispm-auto-title nil)
               (lispm-sandbox-level 'none)
               (lispm-auto-approve-all t)
               (lispm-tool-action-functions nil)
               (lispm-max-steps 16)
               (lispm-backends `((bench-api :api anthropic :url ,url
                                            :model "claude-bench" :key "bench-key")))
               (lispm-backend 'bench-api)
               (lispm-api-function #'lispm-api-stream)
               (lispm-api-kernel-sse-decode (not (string= mode "elisp")))
               (lispm-control-plane-mode (if (string= mode "kernel-actors") 'auto 'elisp))
               (lispm-control-plane-runtime-function (lambda (&optional _dir) rt)))
          (lispm-kernel-exec-mode (if (string= mode "elisp") -1 1))
          (cl-letf (((symbol-function 'lispm-kernel-exec--runtime)
                     (lambda (&rest _) rt)))
            (dotimes (i count)
              (let ((bname (format "bench-buf-%02d" i))
                    (vname (format " *bench-view-%02d*" i)))
                (let ((tb (get-buffer-create bname)))
                  (with-current-buffer tb
                    (erase-buffer)
                    (insert "line1\nOLD\nline3\n"))
                  (push tb target-bufs))
                (let ((ag (lispm-register-agent
                           (intern (format "bench-%02d" i))
                           :root workspace
                           :policy '((read . auto) (write . auto) (shell . auto)))))
                  (when (> i 0)
                    (let ((vb (get-buffer-create vname)))
                      (push vb view-bufs)
                      ;; Runtime `eval' uses `lispm-core''s loaded struct setter
                      ;; without requiring `lispm-core' at compile time.
                      (eval `(setf (lispm-agent-view ',ag) ',vb) t)))
                  (push ag agents))))
            (setq target-bufs (nreverse target-bufs)
                  agents (nreverse agents))
            (advice-add 'lispm-kernel--handle :before frame-counter)
            (let ((start (float-time))
                  (gcs-start gcs-done)
                  (gc-start gc-elapsed)
                  (deadline nil)
                  (end nil)
                  (probe nil)
                  (stats nil))
              (lispm-kernel-agent-bench--start-probe)
              (unwind-protect
                  (progn
                    (dotimes (i count)
                      (let ((idx i)
                            (ag (nth i agents)))
                        (lispm-tell ag (format "bench-target:bench-buf-%02d" idx)
                                    :callback (lambda (ans) (aset replies idx ans)))))
                    (setq deadline (+ (float-time) 60.0))
                    (while (and (< (float-time) deadline)
                                (not (cl-every #'identity replies)))
                      (accept-process-output nil 0.005)
                      (when rt (lispm-kernel-dispatch rt)))
                    (while (and (< (float-time) deadline)
                                (not (cl-every (lambda (ag) (eq (lispm-agent-state ag) 'idle))
                                               agents)))
                      (accept-process-output nil 0.005)
                      (when rt (lispm-kernel-dispatch rt)))
                    (setq end (float-time))
                    (unless (cl-every #'identity replies)
                      (error "Timed out waiting for %d/%d agent replies in %s"
                             (cl-count-if #'null replies) count mode)))
                (unless end (setq end (float-time)))
                (sleep-for 0.01)
                (setq probe (lispm-kernel-agent-bench--stop-probe)))
              (advice-remove 'lispm-kernel--handle frame-counter)
              (lispm-kernel-agent-bench--verify-agents agents target-bufs replies)
              (setq stats (lispm-kernel-agent-bench--query-stats rt))
              (let* ((wall-ms (* 1000.0 (- end start)))
                     (throughput (if (> wall-ms 0.0)
                                     (/ (* 1000.0 count) wall-ms)
                                   0.0))
                     (heap-bytes (plist-get stats :heap))
                     (heap-mb (if (numberp heap-bytes)
                                  (/ (float heap-bytes) (* 1024.0 1024.0))
                                0.0)))
                (list (cons 'mode mode)
                      (cons 'agents count)
                      (cons 'wall_ms wall-ms)
                      (cons 'throughput_agents_per_sec throughput)
                      (cons 'event_loop_p50_ms (plist-get probe :p50))
                      (cons 'event_loop_p95_ms (plist-get probe :p95))
                      (cons 'event_loop_p99_ms (plist-get probe :p99))
                      (cons 'event_loop_max_ms (plist-get probe :max))
                      (cons 'stalls_over_16ms (plist-get probe :stalls-over-16ms))
                      (cons 'timer_samples (plist-get probe :samples))
                      (cons 'emacs_gcs (- gcs-done gcs-start))
                      (cons 'emacs_gc_ms (* 1000.0 (- gc-elapsed gc-start)))
                      (cons 'wire_frames lispm-kernel-agent-bench--frames)
                      (cons 'kernel_heap_mb heap-mb)
                      (cons 'kernel_gc_ms (or (plist-get stats :gc-milliseconds) 0))
                      (cons 'kernel_outbox_peak (or (plist-get stats :outbox-peak) 0))
                      (cons 'kernel_reactor_peak (or (plist-get stats :peak-queued) 0)))))))
      (ignore-errors (lispm-job-cancel-all))
      (dolist (ag agents)
        (ignore-errors (lispm-unwatch ag))
        (when-let* ((sb (lispm-agent-buffer ag))
                    ((buffer-live-p sb)))
          (with-current-buffer sb (set-buffer-modified-p nil))
          (let ((kill-buffer-query-functions nil)) (kill-buffer sb))))
      (dolist (b (append target-bufs view-bufs))
        (when (buffer-live-p b)
          (with-current-buffer b (set-buffer-modified-p nil))
          (let ((kill-buffer-query-functions nil)) (kill-buffer b))))
      (when (fboundp 'lispm-control-plane-reset)
        (ignore-errors (lispm-control-plane-reset)))
      (advice-remove 'lispm-kernel--handle frame-counter)
      (fset 'lispm-kernel-exec--runtime orig-runtime-fn)
      (lispm-kernel-exec-mode (if prev-exec-mode 1 -1))
      (when rt (ignore-errors (lispm-kernel-stop rt)))
      (ignore-errors (delete-directory tmp t)))))

(defun lispm-kernel-agent-bench-main ()
  "Entry point for running one multi-agent benchmark trial from env vars."
  (when-let* ((deps (getenv "LISPM_BENCH_AGENT_DEPS"))
              ((file-directory-p deps)))
    (require 'package)
    (setq package-user-dir (expand-file-name deps))
    (package-initialize))
  (require 'lispm)
  (require 'lispm-control-plane nil t)
  (let* ((mode (or (getenv "LISPM_BENCH_MODE") "kernel-actors"))
         (count (string-to-number (or (getenv "LISPM_BENCH_AGENTS") "8")))
         (url (or (getenv "LISPM_BENCH_URL")
                  (error "LISPM_BENCH_URL is required")))
         (workspace (or (getenv "LISPM_BENCH_WORKSPACE")
                        (error "LISPM_BENCH_WORKSPACE is required")))
         (report (lispm-kernel-agent-bench--run-once mode count url workspace)))
    (princ "BENCH-JSON\n")
    (princ (json-encode report))
    (princ "\n")))

(when (and noninteractive (getenv "LISPM_BENCH_AGENTS_RUN"))
  (lispm-kernel-agent-bench-main))

(provide 'agent-control-plane)
;;; agent-control-plane.el ends here
