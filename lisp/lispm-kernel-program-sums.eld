;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "6608f7b2b9583348"
 :programs (("aarch64-apple-darwin" . "422159de9c020f5789ba5283bc84dd94944fd328c5a3a156d3a92443cc6794a9")
            ("x86_64-apple-darwin" . "ed4107370e824228b4259d480a2a2fcc6b4a22dae0fc7029b713d1546fd63e29")
            ("x86_64-unknown-linux-gnu" . "944fad02a6007d3fc220b444da8cb17b71fb1f7b6b49ca767d57993740ffde63")))
