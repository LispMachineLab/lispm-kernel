# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   make              build the kernel program, build/lispm-kernel
#   make test         the kernel's own tests, then Emacs's with that program
#   make test-lisp    the kernel's own tests
#   make test-emacs   Emacs's tests (LispM Desktop's and lispm-agent's beside, or
#                     LISPM_DESKTOP_ROOT and LISPM_AGENT)
#   make compile      byte-compile the Emacs Lisp, warnings failing it
#   make pin          pin the published programs of these sources
#   make check-pins   check the pins against the release

SBCL ?= sbcl
EMACS ?= emacs
LISPM_DESKTOP_ROOT ?= ../lispm-desktop
# The editor's agents, whose session readers the kernel feeds.
LISPM_AGENT ?= $(LISPM_DESKTOP_ROOT)/../lispm-agent/lisp
SBCL_RUN = $(SBCL) --non-interactive --no-sysinit --no-userinit
PROGRAM = build/lispm-kernel
SOURCES = lispm-kernel.asd scripts/build.lisp $(wildcard src/*.lisp)
DESKTOP = $(wildcard $(LISPM_DESKTOP_ROOT)/lisp/lispm-desktop-ai.el)
EMACS_BATCH = $(EMACS) -Q --batch -L lisp $(if $(DESKTOP),-L $(LISPM_DESKTOP_ROOT)/lisp -L $(LISPM_AGENT))

.PHONY: all test test-lisp test-emacs compile pin check-pins clean

all: $(PROGRAM)

$(PROGRAM): $(SOURCES)
	$(SBCL_RUN) --load scripts/build.lisp

test: test-lisp test-emacs

test-lisp:
	$(SBCL_RUN) --eval '(require :asdf)' --eval '(push (uiop:getcwd) asdf:*central-registry*)' \
	  --eval '(asdf:test-system "lispm-kernel")'

test-emacs: $(PROGRAM)
	LISPM_KERNEL_PROGRAM=$(abspath $(PROGRAM)) $(EMACS_BATCH) \
	  -l test/lispm-kernel-test.el -l test/lispm-kernel-program-test.el -l test/lispm-kernel-package-test.el \
	  -l test/lispm-kernel-exec-test.el \
	  $(if $(DESKTOP),-l test/lispm-kernel-desktop-test.el) \
	  -f ert-run-tests-batch-and-exit
	$(if $(DESKTOP),,@echo "No LispM Desktop at $(LISPM_DESKTOP_ROOT): its tests were skipped")

compile:
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile lisp/*.el
	/bin/rm -f lisp/*.elc

pin:
	$(EMACS) -Q --batch -L lisp -l lispm-kernel-program -f lispm-kernel-program-batch-pin

check-pins:
	LISPM_KERNEL_PIN_CHECK=1 $(EMACS) -Q --batch -L lisp -l lispm-kernel-program \
	  -f lispm-kernel-program-batch-pin

clean:
	/bin/rm -rf build
