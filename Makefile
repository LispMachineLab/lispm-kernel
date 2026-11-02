# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
#
#   make              build the kernel program, build/lispm-kernel
#   make test         the kernel's own tests, then Emacs's with that program
#   make test-lisp    the kernel's own tests
#   make test-emacs   Emacs's tests (lispm-agent's beside, or LISPM_AGENT)
#   make compile      byte-compile the Emacs Lisp, warnings failing it
#   make bench        measure session discovery against Emacs's own reader
#   make pin          pin the published programs of these sources
#   make check-pins   check the pins against the release

SBCL ?= sbcl
EMACS ?= emacs
# lisp/ of lispm-agent, the editor's agents, whose session readers the
# kernel feeds: a checkout beside this one by default.
LISPM_AGENT ?= ../lispm-agent/lisp
# LispM Kit, whose engine translates the agent's words, and LispM UI,
# which asks for it: checkouts beside this one by default.
LISPM_KIT ?= ../lispm-kit
LISPM_UI ?= ../lispm-ui
# LispM Desktop's lisp/, whose terminals and frame clock the terminals
# benchmark runs with: a checkout beside this one by default.
LISPM_DESKTOP ?= ../lispm-desktop/lisp
# The session benchmark, see docs/benchmark.md.  BENCH_TERMINALS=8
# measures discovery while the desktop's terminals draw.
BENCH_REPEATS ?= 3
BENCH_TERMINALS ?= 0
BENCH_OUTPUT ?= docs/session-benchmark.json
SBCL_RUN = $(SBCL) --non-interactive --no-sysinit --no-userinit
PROGRAM = build/lispm-kernel
SOURCES = lispm-kernel.asd scripts/build.lisp $(wildcard src/*.lisp)
AGENTS = $(wildcard $(LISPM_AGENT)/lispm-agents.el)
EMACS_BATCH = $(EMACS) -Q --batch -L lisp $(if $(AGENTS),-L $(LISPM_KIT) -L $(LISPM_UI) -L $(LISPM_AGENT))

.PHONY: all test test-lisp test-emacs compile bench pin check-pins clean

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
	  $(if $(AGENTS),-l test/lispm-kernel-desktop-test.el) \
	  -f ert-run-tests-batch-and-exit
	$(if $(AGENTS),,@echo "No lispm-agent at $(LISPM_AGENT): the tests of the agents' sessions were skipped")

compile:
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile lisp/*.el
	/bin/rm -f lisp/*.elc

bench: $(PROGRAM)
	python3 scripts/bench-sessions.py --emacs $(EMACS) --make $(MAKE) \
	  --repeats $(BENCH_REPEATS) --terminals $(BENCH_TERMINALS) \
	  --agent $(LISPM_AGENT) --kit $(LISPM_KIT) --ui $(LISPM_UI) \
	  --desktop $(LISPM_DESKTOP) --output $(BENCH_OUTPUT)

pin:
	$(EMACS) -Q --batch -L lisp -l lispm-kernel-program -f lispm-kernel-program-batch-pin

check-pins:
	LISPM_KERNEL_PIN_CHECK=1 $(EMACS) -Q --batch -L lisp -l lispm-kernel-program \
	  -f lispm-kernel-program-batch-pin

clean:
	/bin/rm -rf build
