#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# ── PROVENANCE (local banner; the body below is upstream verbatim) ──────────
# Adopted from `hyperpolymath/standards` at scripts/run-shell-test-suite.sh
# (pinned upstream 2ccc38eaaf8787034ed099e0b72c9ca8b85dc563, retrieved
# 2026-09-28). The estate's CI/CD catalogue says to *call* reusable workflows
# and *copy* non-reusable ones; this script is not exposed as a workflow_call,
# so it is copied. Body unmodified: discovery is `tests/*.sh` and
# `scripts/tests/*.sh`, fail-closed if discovery finds nothing.
#
# Local consequence, stated because it is easy to trip over: discovery is
# relative to the current directory, so run this from the repository root.
# Non-shell tests are not discovered by it — `tests/readme-badges-test.sh`
# exists to bring the Python suite under this runner.
# ───────────────────────────────────────────────────────────────────────────
# Canonical fail-closed shell test discovery used by CI and `just test`.
set -uo pipefail

mapfile -t TESTS < <(
  {
    find tests -maxdepth 1 -name '*.sh' -type f
    find scripts/tests -maxdepth 1 -name '*.sh' -type f
  } | sort
)

if [ "${#TESTS[@]}" -eq 0 ]; then
  echo "ERROR: no tests found under tests/ or scripts/tests/ — discovery is broken." >&2
  exit 1
fi

echo "Discovered ${#TESTS[@]} test file(s)."
failed=0

for test_file in "${TESTS[@]}"; do
  echo "::group::$test_file"

  if bash "$test_file"; then
    echo "PASS $test_file"
  else
    status=$?
    echo "::error file=$test_file::$test_file failed (exit $status)"
    failed=$((failed + 1))
  fi

  echo "::endgroup::"
done

echo
if [ "$failed" -gt 0 ]; then
  echo "ERROR: $failed of ${#TESTS[@]} test file(s) failed." >&2
  exit 1
fi

echo "All ${#TESTS[@]} test file(s) passed."
