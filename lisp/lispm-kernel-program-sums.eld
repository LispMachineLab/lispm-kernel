;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "334f344291f04ea3"
 :programs (("aarch64-apple-darwin" . "0ceadb58df787c986e005520e575605cb74bf969694614aeebaca40212d1b480")
            ("x86_64-apple-darwin" . "da0fca89066509d69f5b4671b359d22ed10e8f78d8686a0617150a0b33997147")
            ("x86_64-unknown-linux-gnu" . "4170aafb493a7961266da92efb67add384e01e344d0e64e7ef1022682a1e83cf")))
