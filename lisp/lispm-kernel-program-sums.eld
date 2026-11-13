;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "34dc1a2f2e7e9421"
 :programs (("aarch64-apple-darwin" . "2c2aae427884032d73cb1c6aff9f7e074c32872e14051d42ecfa5cc5f386b3f9")
            ("x86_64-apple-darwin" . "0fcdc976c5a3e5f5b65b7400efa242c4d5fd95fac038d1efc2613fafbff17839")
            ("x86_64-unknown-linux-gnu" . "222fa5fbbc80b37df4babca789295ce6cd531326df42e8b399119e4541ccf2bb")))
