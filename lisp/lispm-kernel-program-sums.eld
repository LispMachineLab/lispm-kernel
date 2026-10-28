;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "2ee4c5037f918de3"
 :programs (("aarch64-apple-darwin" . "fe31a22f4a1e07d463e5de46743c42c7069a199151a797eef4011736540ba802")
            ("x86_64-apple-darwin" . "4056e05ab7c03af84250e4d3da231422f782970f6d2a0e11219477bd3f60965e")
            ("x86_64-unknown-linux-gnu" . "33599a4efba93d9737a1491ba042ad9a04c32535046ef2cd49408f5488b220e4")))
