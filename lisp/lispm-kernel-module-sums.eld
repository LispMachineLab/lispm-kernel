;;; lispm-kernel-module-sums.eld --- The kernel modules LispM downloads  -*- lisp-data -*-
;; SPDX-License-Identifier: AGPL-3.0-or-later

;; The SHA-256 of each library of the release kernel-module-VERSION, the
;; module lispm-kernel-library.el downloads for these sources: a library
;; whose SHA-256 is not the one here is refused.  VERSION must be the
;; version of the sources beside this file.  scripts/pin-module.py writes
;; it once the kernel module workflow has published that release.

(:version "ce8795fedf137495"
 :modules (("aarch64-apple-darwin" . "d47a63748733ee58f516f27a3f98800104f1ccd627cd116a85d4557985ff1776")
           ("x86_64-apple-darwin" . "4c51097b832c1c24cb87e58c9d93806daeb6e83948e02ccdf987e18ffab1a8e3")
           ("x86_64-unknown-linux-gnu" . "1aa78141cd66a6b03e468b30a9f5a91d5e9bd102cebbc1bd4640c953de18c3e1")))
