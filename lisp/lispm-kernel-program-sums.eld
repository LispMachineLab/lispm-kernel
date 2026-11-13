;;; lispm-kernel-program-sums.eld --- The kernel programs LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each program of the release kernel-program-VERSION, as
;; published, compressed: the program lispm-kernel-program.el downloads
;; for these sources.  A program whose SHA-256 is not the one here is
;; refused.  VERSION must be the version of the sources beside this file.
;; `lispm-kernel-program-batch-pin' writes it once the kernel-program
;; workflow has published that release.

(:version "074d2ff4d4145014"
 :programs (("aarch64-apple-darwin" . "f4ff8d043530a1e253ce498a5475735d419febc4c9877c27758abfa9098c069f")
            ("x86_64-apple-darwin" . "d26c6bcfe654969c3d8c7d7be0dddf9aebca1a4d7659248e9efdaee1d6d60384")
            ("x86_64-unknown-linux-gnu" . "bbbb78b9a9dcd82e4b7a8ff2beb272acd45cbe5abaa937bf3bbde83e2bb82614")))
