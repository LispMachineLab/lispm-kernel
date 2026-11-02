;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "c617927c71c449d4"
 :programs (("aarch64-apple-darwin" . "84d16b65b1a7529fde141680d31023a03fc8f7dabb0a2a31f97ab7c769149fdd")
            ("x86_64-apple-darwin" . "1d8b30d410789f5dae04475ab66ce84145dc9b9df3e2e9827fce7e4dbaa19815")
            ("x86_64-unknown-linux-gnu" . "872e805c5da6fdbe743c88a6be89660c31b19000e7ec8caaebdccd124c073916")))
