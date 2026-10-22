#!/bin/sh
# Copyright (C) 2026  Ryan.K
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# scripts/build-sbcl.sh VERSION SHA256 PREFIX
#
# Build SBCL VERSION from its source release, refused unless its SHA-256
# is SHA256, and install it in PREFIX.  The kernel program is SBCL's
# runtime with the kernel's core, so this is what the release workflow
# builds it with: without core compression, so the program needs nothing
# but the system's C library, and, on macOS, for the oldest macOS
# MACOSX_DEPLOYMENT_TARGET names.  Building needs an SBCL already, any.
set -eu

version=$1
sha256=$2
prefix=$3

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl --fail --silent --show-error --location --retry 3 \
  --output "$work/sbcl.tar.bz2" \
  "https://downloads.sourceforge.net/project/sbcl/sbcl/$version/sbcl-$version-source.tar.bz2"
if command -v sha256sum >/dev/null; then
  actual=$(sha256sum "$work/sbcl.tar.bz2" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$work/sbcl.tar.bz2" | cut -d' ' -f1)
fi
if [ "$actual" != "$sha256" ]; then
  echo "sbcl-$version-source.tar.bz2 is not the one pinned: its SHA-256 is $actual" >&2
  exit 1
fi

tar -xjf "$work/sbcl.tar.bz2" -C "$work"
cd "$work/sbcl-$version"
sh make.sh --prefix="$prefix" --with-sb-thread --without-sb-core-compression
# The SBCL that built it may have been told where its own home is.
unset SBCL_HOME
sh install.sh
