;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "414c7e2f517bf325"
 :programs (("aarch64-apple-darwin" . "64094bd99c2cea21276e9c9795301edf9c4b1b51e25b02f9dfe324e968ced099")
            ("x86_64-apple-darwin" . "992c6e1afeaeb67ec0ecdaa157571504023a47d42af51a5a6751fe92d14c55a1")
            ("x86_64-unknown-linux-gnu" . "972f01f5db67725cf60d8bee8ff116a51470b034233f2f4a8dadb6cd856f48f7")))
