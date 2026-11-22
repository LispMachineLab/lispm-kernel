;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "4758c90823bbe523"
 :programs (("aarch64-apple-darwin" . "394db60596ecf1c45001b8d7e706633f630fcaa3167641e609cb14e90c9b177d")
            ("x86_64-apple-darwin" . "83311dda77306872827cf55ccac047435c28f5143389dc672f188345ce731742")
            ("x86_64-unknown-linux-gnu" . "ea99850dd34b9f61690e4f28d600e94cb79611bfb1e52cfba91517456e1555ad")))
