;;; session-discovery.el --- Compare current desktop parsing with kernel -*- lexical-binding: t; -*-

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

;; Synthetic fixture benchmark. Timer lateness is a responsiveness proxy,
;; never an input-to-paint measurement. Does not read the user's transcripts.
(require 'lispm-desktop-agent-codex)
(require 'lispm-kernel-sessions)
(module-load (getenv "LISPM_KERNEL_MODULE"))

(defun lispm-kernel-bench--measure (run)
  (let ((last (float-time)) (maximum 0.0) (samples 0) timer finished result
        (start (float-time)) (initial-gcs gcs-done) (initial-gc-time gc-elapsed))
    (setq timer (run-at-time 0.002 0.002
                  (lambda ()
                    (let ((now (float-time)))
                      (setq maximum (max maximum (max 0 (- now last 0.002)))
                            last now samples (1+ samples))))))
    (unwind-protect
        (progn
          (run-at-time 0.005 nil
            (lambda () (funcall run (lambda (value) (setq result value finished t)))))
          (let ((deadline (+ start 30)))
            (while (and (not finished) (< (float-time) deadline)) (sleep-for 0.001))
            (unless finished (error "Benchmark timed out")))
          ;; Let the late probe execute after a synchronous workload finishes.
          (sleep-for 0.005)
          (list :elapsed_ms (* 1000 (- (float-time) start))
                :max_probe_lateness_ms (* 1000 maximum) :probe_samples samples
                :rows (length result) :gcs (- gcs-done initial-gcs)
                :gc_ms (* 1000 (- gc-elapsed initial-gc-time))))
      (cancel-timer timer))))

(let* ((directory (make-temp-file "lispm-kernel-bench-" t))
       (root (expand-file-name "sessions" directory))
       (runtime (lispm-kernel-create))
       (count 256)
       (filler (concat "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":\""
                       (make-string 512 ?x) "\"}}\n"))
       (terminal-count (string-to-number (or (getenv "LISPM_BENCH_TERMINALS") "0")))
       (broker-enabled (equal (getenv "LISPM_BENCH_BROKER") "1"))
       terminals results)
  (unwind-protect
      (progn
        (make-directory root)
        (dotimes (index count)
          (with-temp-file (expand-file-name (format "rollout-%04d.jsonl" index) root)
            (insert (format "{\"type\":\"session_meta\",\"payload\":{\"id\":\"%d\",\"cwd\":\"/fixture\"}}\n" index)
                    (format "{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"fixture %d\"}}\n" index))
            (dotimes (_ 128) (insert filler))))
        (when (> terminal-count 0)
          (require 'lispm-desktop-term)
          (unless (lispm-desktop-term-ready-p) (error "Build the desktop terminal module first"))
          (dotimes (index terminal-count)
            (push (lispm-desktop-term-make
                   (format "lispm-kernel-bench-%d" index) "/bin/sh"
                   '("-c" "i=0; while [ $i -lt 100 ]; do j=0; while [ $j -lt 200 ]; do printf 'benchmark \033[32mterminal output\033[0m abcdefghijklmnopqrstuvwxyz0123456789\n'; j=$((j+1)); done; i=$((i+1)); sleep 0.02; done")
                   directory) terminals))
          (switch-to-buffer (car terminals))
          (lispm-desktop-term--follow-windows)
          (when broker-enabled
            (require 'lispm-kernel-broker)
            (lispm-kernel-broker-start runtime)))
        (let ((lispm-desktop-agent-codex-sessions-directory root)
              (lispm-desktop-agent-codex-index-file (expand-file-name "session_index.jsonl" directory))
              (lispm-desktop-agent--session-cache (make-hash-table :test #'equal)))
          (dolist (mode '(desktop-cold desktop-warm native-cold native-warm))
            (let ((result
                   (lispm-kernel-bench--measure
                    (if (memq mode '(desktop-cold desktop-warm))
                        (lambda (done) (funcall done (lispm-desktop-agent-codex-sessions)))
                      (lambda (done)
                        (let (request (deadline (+ (float-time) 3)))
                          (while (and (not (integerp request)) (< (float-time) deadline))
                            (setq request
                                  (lispm-kernel-scan-sessions runtime 'codex root
                                    (lambda (rows summary)
                                      (when (plist-get summary :error) (error "%S" summary))
                                      (funcall done rows))))
                            (unless (integerp request) (sleep-for 0.001)))
                          (unless (integerp request) (error "Admission failed"))))))))
              (unless (= (plist-get result :rows) count) (error "Lost sessions: %S" result))
              (push (cons mode result) results))))
        (princ (json-serialize (list :fixture_files count :filler_lines_per_file 128
                                    :broker (if broker-enabled "shared" "independent")
                                    :terminals terminal-count :visible_terminals (if (> terminal-count 0) 1 0)
                                    :kind "synthetic timer-lateness proxy; no input-to-paint claim"
                                    :results (vconcat (mapcar (lambda (entry)
                                                               (append (list :mode (symbol-name (car entry))) (cdr entry)))
                                                             (nreverse results)))))))
    (when (and broker-enabled (fboundp 'lispm-kernel-broker-stop)) (lispm-kernel-broker-stop))
    (dolist (buffer terminals)
      (when (buffer-live-p buffer)
        (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))))
    (lispm-kernel-shutdown runtime)
    (delete-directory directory t)))
