#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Bring the existing README badge regression suite under the canonical runner.
#
# The estate's canonical shell test discovery (`scripts/run-shell-test-suite.sh`)
# finds `tests/*.sh` and `scripts/tests/*.sh`. It is a *shell* discovery, so
# `scripts/tests/test_readme_badges.py` was invisible to it: the suite existed,
# passed when invoked by hand, and was never run by anything. A test that is
# never discovered is not evidence.
#
# This wrapper makes it discoverable without duplicating a single assertion —
# the Python suite stays the single source of truth for what is asserted.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE="$ROOT/scripts/tests/test_readme_badges.py"

if [ ! -f "$SUITE" ]; then
  echo "readme-badges-test: expected suite not found at $SUITE" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  # A missing interpreter is "no check performed", not a pass.
  echo "readme-badges-test: python3 not available — NO CHECK WAS PERFORMED" >&2
  exit 2
fi

cd "$ROOT" || exit 2
python3 -m unittest -v scripts.tests.test_readme_badges
