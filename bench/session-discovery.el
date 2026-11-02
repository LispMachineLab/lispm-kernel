;;; session-discovery.el --- Benchmark session discovery -*- lexical-binding: t; -*-

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

;; A synthetic benchmark of session discovery: generated Codex transcripts
;; are read by the kernel and by lispm-agent's own reader, cold and warm,
;; with or without terminal output.  Each case reports how long it took and
;; how late a 2 ms timer ran while it did.  Timer lateness is a
;; responsiveness proxy, never an input-to-paint measurement, and batch
;; Emacs has no redisplay.  No transcript of the user's is read.
;;
;; Run it through scripts/bench-sessions.py, which sets the paths and
;; repeats it; or by hand, with the agents' Lisp and the desktop's beside:
;;
;;   LISPM_KERNEL_PROGRAM=build/lispm-kernel \
;;   emacs -Q --batch -L lisp -L ../lispm-agent/lisp -L ../lispm-kit \
;;     -L ../lispm-ui -L ../lispm-desktop/lisp \
;;     -l bench/session-discovery.el
;;
;; Environment:
;;   LISPM_KERNEL_PROGRAM  the kernel program to run (required)
;;   LISPM_BENCH_COUNT     transcripts to generate (default 256)
;;   LISPM_BENCH_FILLER    filler lines per transcript (default 128)
;;   LISPM_BENCH_TERMINALS terminals writing at once (default 0, one shown)
;;   LISPM_BENCH_ORDER     elisp-first (default) or kernel-first
;;
;; The JSON report is printed after the line `BENCH-JSON'.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'lispm-kernel)
(require 'lispm-kernel-sessions)
(require 'lispm-agents-codex)

(declare-function lispm-desktop-frame-add-client "lispm-desktop-frame" (name function &optional depth))
(declare-function lispm-desktop-frame-remove-client "lispm-desktop-frame" (name))
(declare-function lispm-desktop-frame-request "lispm-desktop-frame" (name))
(declare-function lispm-desktop-term-make "lispm-desktop-term" (name program &optional args directory))
(declare-function lispm-desktop-term-ready-p "lispm-desktop-term" ())
(declare-function lispm-desktop-term--follow-windows "lispm-desktop-term" ())

(defvar lispm-kernel-bench--interval 0.002
  "Seconds between the probe timer's runs.")

(defvar lispm-kernel-bench--samples nil
  "How late each probe run was, in milliseconds.")

(defvar lispm-kernel-bench--timer nil
  "The probe timer while it runs.")

(defvar lispm-kernel-bench--runtime nil
  "The kernel runtime under test, while it runs.")

;;;; Measuring

(defun lispm-kernel-bench--percentile (values fraction)
  "Return the FRACTION quantile of VALUES, a list of numbers, or 0."
  (if (null values)
      0
    (let* ((sorted (sort (copy-sequence values) #'<))
           (index (min (1- (length sorted))
                       (floor (* fraction (length sorted))))))
      (nth index sorted))))

(defun lispm-kernel-bench--start-probe ()
  "Start timing how late a timer of the probe interval runs."
  (setq lispm-kernel-bench--samples nil)
  (let ((last (float-time)))
    (setq lispm-kernel-bench--timer
          (run-at-time lispm-kernel-bench--interval lispm-kernel-bench--interval
                       (lambda ()
                         (let ((now (float-time)))
                           (push (max 0 (* 1000 (- now last lispm-kernel-bench--interval)))
                                 lispm-kernel-bench--samples)
                           (setq last now)))))))

(defun lispm-kernel-bench--stop-probe ()
  "Stop the probe and return its samples' count and quantiles."
  (when lispm-kernel-bench--timer
    (cancel-timer lispm-kernel-bench--timer)
    (setq lispm-kernel-bench--timer nil))
  (let ((values (nreverse lispm-kernel-bench--samples)))
    (setq lispm-kernel-bench--samples nil)
    (list :samples (length values)
          :p50 (lispm-kernel-bench--percentile values 0.50)
          :p95 (lispm-kernel-bench--percentile values 0.95)
          :p99 (lispm-kernel-bench--percentile values 0.99)
          :max (if values (apply #'max values) 0))))

(defun lispm-kernel-bench--measure (function)
  "Run FUNCTION with the probe timing it; return a plist of what was measured.
FUNCTION takes no argument and returns :rows and :ids of the sessions it
read, and :summary for the kernel."
  (let ((start (float-time))
        (gcs gcs-done)
        (gc-time gc-elapsed)
        (result nil)
        (end nil)
        (probe nil))
    (lispm-kernel-bench--start-probe)
    (unwind-protect
        (setq result (funcall function)
              end (float-time)
              gcs (- gcs-done gcs)
              gc-time (* 1000 (- gc-elapsed gc-time)))
      (when (null end)
        (setq end (float-time))
        (lispm-kernel-bench--stop-probe)))
    ;; Let the timer that was held up run and be recorded.
    (sleep-for 0.01)
    (setq probe (lispm-kernel-bench--stop-probe))
    (append (list :elapsed-ms (* 1000 (- end start))
                  :gcs gcs
                  :gc-ms gc-time
                  :probe probe)
            result)))

;;;; Fixtures

(defun lispm-kernel-bench--filler ()
  "Return one Codex transcript line, an assistant message of 512 bytes."
  (concat "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\","
          "\"role\":\"assistant\",\"content\":\"" (make-string 512 ?x) "\"}}\n"))

(defconst lispm-kernel-bench--ended-turn
  "{\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\"}}\n"
  "A Codex transcript line that ends a turn.")

(defconst lispm-kernel-bench--long-factor 6
  "How many times more filler lines a long transcript has than a short one.")

(defun lispm-kernel-bench--fixtures (root count filler-lines)
  "Write COUNT synthetic Codex transcripts below ROOT and return the bytes
written.  Every fourth is short, the one after it short with its turn ended,
then long, then long with its ended turn: a short one's head and tail hold
all of it, while a long one's do not, so its turn is looked for at the end
of it.  Each has FILLER-LINES filler lines, a long one six times that."
  (make-directory root t)
  (let ((filler (lispm-kernel-bench--filler))
        (bytes 0))
    (dotimes (index count)
      (let* ((kind (mod index 4))
             (turn-p (cl-oddp kind))
             (lines (if (>= kind 2) (* lispm-kernel-bench--long-factor filler-lines)
                      filler-lines)))
        (with-temp-file (expand-file-name (format "rollout-%04d.jsonl" index) root)
          (insert (format "{\"type\":\"session_meta\",\"payload\":{\"id\":\"%d\",\"cwd\":\"/fixture\",\"timestamp\":\"2026-01-01T00:00:00.000Z\"}}\n"
                          index))
          (insert (format "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"fixture %d\"}}\n"
                          index))
          (dotimes (_ lines) (insert filler))
          (when turn-p (insert lispm-kernel-bench--ended-turn))
          (setq bytes (+ bytes (buffer-size))))))
    bytes))

;;;; Terminals

(defconst lispm-kernel-bench--terminal-command
  (concat "i=0; while [ $i -lt 1000 ]; do "
          "j=0; while [ $j -lt 100 ]; do "
          "printf 'benchmark \\033[32mterminal output\\033[0m abcdefghijklmnopqrstuvwxyz0123456789\\n'; "
          "j=$((j+1)); done; i=$((i+1)); sleep 0.02; done")
  "The program each benchmark terminal runs: about 300 KiB a second.")

(defun lispm-kernel-bench--terminals (directory count)
  "Start COUNT terminals in DIRECTORY, one shown, and return their buffers."
  (when (> count 0)
    (require 'lispm-desktop-term)
    (require 'lispm-desktop-frame)
    (unless (lispm-desktop-term-ready-p)
      (error "lispm-desktop-term is not ready: build or download its module"))
    (let ((buffers nil))
      (dotimes (index count)
        (push (lispm-desktop-term-make
               (format "lispm-kernel-bench-%d" index) "/bin/sh"
               (list "-c" lispm-kernel-bench--terminal-command) directory)
              buffers))
      (setq buffers (nreverse buffers))
      (switch-to-buffer (car buffers))
      (lispm-desktop-term--follow-windows)
      buffers)))

;;;; The two readers

(defun lispm-kernel-bench--elisp (root)
  "Read ROOT's sessions as lispm-agent does; return :rows and :ids."
  (let* ((lispm-agents-codex-sessions-directory root)
         (lispm-agents-codex-index-file
          (expand-file-name "session_index.jsonl" (file-name-directory (directory-file-name root))))
         (sessions (lispm-agents-codex-sessions)))
    (list :rows (length sessions)
          :ids (sort (mapcar (lambda (session) (plist-get session :id)) sessions)
                     #'string<))))

(defun lispm-kernel-bench--schedule-on-frame (_runtime)
  "Ask the frame clock to take in the kernel's messages; return non-nil."
  (lispm-desktop-frame-request 'lispm-kernel-bench-kernel)
  t)

(defun lispm-kernel-bench--scan (runtime root direct-p)
  "Have RUNTIME read ROOT's sessions; return :rows, :ids and :summary.
DIRECT-P says to call `lispm-kernel-dispatch' in the wait loop, as the
tests do, rather than let the frame clock take the messages in."
  (let ((sessions nil)
        (summary nil)
        (finished nil)
        (deadline (+ (float-time) 120)))
    (lispm-kernel-submit runtime 'scan-sessions
                         (list :agent 'codex :root root)
                         :owner 1 :generation 1 :timeout 110
                         :on-result
                         (lambda (kind value)
                           (pcase kind
                             ('chunk (dolist (row value) (push row sessions)))
                             ('success (setq summary value finished t))
                             (_ (setq summary (list :error (list kind value))
                                      finished t)))))
    (while (and (not finished) (< (float-time) deadline))
      (accept-process-output nil 0.001)
      (when direct-p (lispm-kernel-dispatch runtime)))
    (unless finished
      (error "The kernel did not finish the scan in time"))
    (when (plist-get summary :error)
      (error "The kernel failed the scan: %S" summary))
    (list :rows (length sessions)
          :ids (sort (mapcar (lambda (row) (plist-get row :id)) sessions) #'string<)
          :summary summary)))

(defun lispm-kernel-bench--ready (runtime direct-p)
  "Wait until RUNTIME answers a ping, so its start is not measured."
  (let (answered)
    (lispm-kernel-ping runtime (lambda (&rest _) (setq answered t)) 'ready)
    (let ((deadline (+ (float-time) 30)))
      (while (and (not answered) (< (float-time) deadline))
        (accept-process-output nil 0.001)
        (when direct-p (lispm-kernel-dispatch runtime))))
    (unless answered (error "The kernel did not answer a ping"))))

(defun lispm-kernel-bench--stats (runtime direct-p)
  "Ask RUNTIME for its stats; return them, or nil when it does not answer."
  (let (answer)
    (lispm-kernel-stats runtime (lambda (plist) (setq answer plist)))
    (let ((deadline (+ (float-time) 5)))
      (while (and (not answer) (< (float-time) deadline))
        (accept-process-output nil 0.001)
        (when direct-p (lispm-kernel-dispatch runtime))))
    answer))

;;;; The report

(defun lispm-kernel-bench--probe-json (probe)
  "Return PROBE as an alist JSON can serialize."
  (list (cons 'samples (plist-get probe :samples))
        (cons 'p50 (plist-get probe :p50))
        (cons 'p95 (plist-get probe :p95))
        (cons 'p99 (plist-get probe :p99))
        (cons 'max (plist-get probe :max))))

(defun lispm-kernel-bench--summary-json (summary)
  "Return SUMMARY, the kernel's scan counts, as an alist, or nil."
  (when (and summary (not (plist-get summary :error)))
    (list (cons 'files (or (plist-get summary :files) 0))
          (cons 'rows (or (plist-get summary :rows) 0))
          (cons 'empty (or (plist-get summary :empty) 0))
          (cons 'skipped (or (plist-get summary :skipped) 0))
          (cons 'cached (or (plist-get summary :cached) 0))
          (cons 'truncated (if (plist-get summary :truncated) t :false))
          (cons 'turn-ended (if (plist-get summary :turn-ended) t :false)))))

(defun lispm-kernel-bench--stats-json (stats)
  "Return STATS, the kernel's plist, as an alist, or nil."
  (when stats
    (list (cons 'requests (or (plist-get stats :requests) 0))
          (cons 'queued (or (plist-get stats :queued) 0))
          (cons 'accepted (or (plist-get stats :accepted) 0))
          (cons 'rejected (or (plist-get stats :rejected) 0))
          (cons 'success (or (plist-get stats :success) 0))
          (cons 'failed (or (plist-get stats :failed) 0))
          (cons 'cancelled (or (plist-get stats :cancelled) 0))
          (cons 'peak-queued (or (plist-get stats :peak-queued) 0))
          (cons 'outbox-peak (or (plist-get stats :outbox-peak) 0))
          (cons 'heap (or (plist-get stats :heap) 0))
          (cons 'gc-milliseconds (or (plist-get stats :gc-milliseconds) 0))
          (cons 'uptime-milliseconds (or (plist-get stats :uptime-milliseconds) 0)))))

(defun lispm-kernel-bench--result-json (mode result)
  "Return the JSON alist of MODE's RESULT."
  (append
   (list (cons 'mode mode)
         (cons 'elapsed_ms (plist-get result :elapsed-ms))
         (cons 'probe (lispm-kernel-bench--probe-json (plist-get result :probe)))
         (cons 'gcs (plist-get result :gcs))
         (cons 'gc_ms (plist-get result :gc-ms))
         (cons 'rows (plist-get result :rows)))
   (let ((summary (lispm-kernel-bench--summary-json (plist-get result :summary))))
     (if summary (list (cons 'summary summary)) nil))))

;;;; Main

(let* ((program (or (getenv "LISPM_KERNEL_PROGRAM")
                    (error "Set LISPM_KERNEL_PROGRAM to the kernel program")))
       (count (string-to-number (or (getenv "LISPM_BENCH_COUNT") "256")))
       (filler-lines (string-to-number (or (getenv "LISPM_BENCH_FILLER") "128")))
       (terminal-count (string-to-number (or (getenv "LISPM_BENCH_TERMINALS") "0")))
       (order (or (getenv "LISPM_BENCH_ORDER") "elisp-first"))
       (elisp-first (equal order "elisp-first"))
       (directory (make-temp-file "lispm-kernel-bench-" t))
       (root (expand-file-name "sessions" directory))
       (runtime nil)
       (terminals nil)
       (results nil)
       (stats-before nil)
       (stats-after nil)
       (bytes 0))
  (unwind-protect
      (progn
        (setq bytes (lispm-kernel-bench--fixtures root count filler-lines))
        (setq terminals (lispm-kernel-bench--terminals directory terminal-count))
        (when terminals
          (setq lispm-kernel-scheduler #'lispm-kernel-bench--schedule-on-frame)
          (lispm-desktop-frame-add-client
           'lispm-kernel-bench-kernel
           (lambda (deadline)
             (when lispm-kernel-bench--runtime
               (let ((lispm-kernel-slice-seconds
                      (max 0.001 (- deadline (float-time)))))
                 (lispm-kernel-dispatch lispm-kernel-bench--runtime))))
           10))
        (setq runtime (lispm-kernel-start program)
              lispm-kernel-bench--runtime runtime)
        (when terminals (lispm-desktop-frame-request 'lispm-kernel-bench-kernel))
        (unless (lispm-kernel-live-p runtime)
          (error "The kernel did not start: %s" program))
        (let ((direct-p (null terminals)))
          (lispm-kernel-bench--ready runtime direct-p)
          (dolist (mode (if elisp-first
                            '("elisp-cold" "kernel-cold" "elisp-warm" "kernel-warm")
                          '("kernel-cold" "elisp-cold" "kernel-warm" "elisp-warm")))
            (let ((kernel-p (string-prefix-p "kernel" mode))
                  (cold-p (string-suffix-p "cold" mode)))
              ;; The kernel's own cache, before and after its cold scan.
              (when (and kernel-p cold-p)
                (setq stats-before (lispm-kernel-bench--stats runtime direct-p)))
              (let ((result
                     (lispm-kernel-bench--measure
                      (if kernel-p
                          (lambda () (lispm-kernel-bench--scan runtime root direct-p))
                        (lambda () (lispm-kernel-bench--elisp root))))))
                (when (and kernel-p cold-p)
                  (setq stats-after (lispm-kernel-bench--stats runtime direct-p)))
                (unless (= (plist-get result :rows) count)
                  (error "%s read %d sessions, not %d"
                         mode (plist-get result :rows) count))
                (push (cons mode result) results)))))
        (setq results (nreverse results))
        ;; Both readers must have read the same sessions.
        (dolist (pair '(("elisp-cold" . "kernel-cold")
                        ("elisp-warm" . "kernel-warm")))
          (let ((elisp (plist-get (cdr (assoc (car pair) results)) :ids))
                (kernel (plist-get (cdr (assoc (cdr pair) results)) :ids)))
            (unless (equal elisp kernel)
              (error "The two readers disagree in %s, %s" (car pair) (cdr pair)))))
        (princ "BENCH-JSON\n")
        (princ
         (json-serialize
          (list (cons 'environment
                      (list (cons 'emacs emacs-version)
                            (cons 'system system-configuration)
                            (cons 'kernel_program program)
                            (cons 'fixture_files count)
                            (cons 'filler_lines_per_file filler-lines)
                            (cons 'long_filler_lines_per_file
                                  (* lispm-kernel-bench--long-factor filler-lines))
                            (cons 'files_ending_a_turn (/ (+ count 1) 2))
                            (cons 'fixture_bytes bytes)
                            (cons 'terminals terminal-count)
                            (cons 'visible_terminals (if (> terminal-count 0) 1 0))
                            (cons 'order order)
                            (cons 'scheduler (if terminals "frame-clock" "timer/direct"))
                            (cons 'slice_seconds lispm-kernel-slice-seconds)
                            (cons 'probe_interval_ms (* 1000 lispm-kernel-bench--interval))
                            (cons 'kind "synthetic fixture; timer lateness is a proxy, not input-to-paint")
                            (cons 'kernel_stats_before
                                  (or (lispm-kernel-bench--stats-json stats-before) :null))
                            (cons 'kernel_stats_after
                                  (or (lispm-kernel-bench--stats-json stats-after) :null))))
                (cons 'results
                      (vconcat (mapcar (lambda (entry)
                                         (lispm-kernel-bench--result-json (car entry) (cdr entry)))
                                       results))))))
        (princ "\n"))
    (when (and terminals (fboundp 'lispm-desktop-frame-remove-client))
      (lispm-desktop-frame-remove-client 'lispm-kernel-bench-kernel))
    (setq lispm-kernel-scheduler nil
          lispm-kernel-bench--runtime nil)
    (when runtime (lispm-kernel-stop runtime))
    (dolist (buffer terminals)
      (when (buffer-live-p buffer)
        (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))
    (delete-directory directory t)))
