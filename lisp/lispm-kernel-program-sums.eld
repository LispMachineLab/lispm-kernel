;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "e02f0caa6c2886d8"
 :programs (("aarch64-apple-darwin" . "8124cf02266ff44d4d2ece755fb5de04ad8664ca075fd12e40c779a709be6900")
            ("x86_64-apple-darwin" . "83093b50ca120fa95666ae2228f9b1d017492ad585df9737d9422e5c51a30e87")
            ("x86_64-unknown-linux-gnu" . "d3cc2a14c9c56bed141a09f5d25ad0506935106fedd1424c35871c678f4a769f")))
