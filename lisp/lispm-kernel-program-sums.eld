;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "ee35da649be8ebee"
 :programs (("aarch64-apple-darwin" . "d40aedbf15bc21febeee4dde556aa10f8a9cc08e8e9640593dc09c66db0c5c32")
            ("x86_64-apple-darwin" . "6623d80e545da52b23527ddd7761ef7a021690c517447dc69c599ccde1506221")
            ("x86_64-unknown-linux-gnu" . "a9233bc0611095c4c8f4cb9d4cede0e1d6021fca69b42dfb9d742f88db9e0bda")))
