#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# check-lock-pins.sh — does every pin actions.lock records actually resolve?
#
# ── The fault this detects ─────────────────────────────────────────────────
#
# A recorded pin can be well-formed and still be dead: a real action repo with
# a commit SHA that does not exist, or an action repository that has been
# deleted, renamed or made private. Actions resolves a pin at *run* time, and
# an unresolvable ref produces **no check run at all** — not a red one. So the
# board looks green and the job never ran. Measured across the estate on
# 2026-07-28: 613 unique (action, SHA) pins, 112 of them (18%) did not resolve,
# present in 876 committed workflow files.
#
# `actions.lock` narrows this but does not close it: the lock records what the
# workflow asked for and what it resolved to on the day it was generated. It
# does not re-ask. This script re-asks.
#
# ── Determinate vs indeterminate: the distinction this script exists for ───
#
#   HARD FAIL on a *determinate negative* — GitHub answered, and the answer was
#   "this does not exist": 404/422 on the commits endpoint while the repo
#   resolves, or 404 on the repository itself.
#
#   DO NOT FAIL on an *indeterminate answer* — 403, 429, 5xx, network loss.
#   Those say nothing about the pin. Failing on them turns any GitHub incident
#   into an estate-wide red treadmill. They are counted and reported LOUDLY as
#   UNVERIFIED, so the gap is visible rather than silently green.
#
#   A fail-open that announces itself is not a fake gate. A fail-open that
#   hides is. Getting this backwards in either direction makes the tool worse
#   than useless, and is why this script's own test drives both branches.
#
# ── Reading the lockfile (upstream rule Y-1, IN FORCE) ─────────────────────
#
# `actions.lock` is YAML. It is read only through `scripts/lib/yaml.sh` (a real
# parser, `yq` first) and then `jq`. Never grep, sed or awk over YAML.
#
# ── Exit contract ──────────────────────────────────────────────────────────
#   0 = every recorded pin resolved (unverified pins are reported, not failed)
#   1 = at least one pin is determinately dead
#   2 = NO CHECK WAS PERFORMED — no parser, unreadable lockfile, no `gh`
#
# Usage: check-lock-pins.sh [REPO_ROOT] [--offline]
#        REPO_ROOT=/path        limit to one repo
#        --offline              parse-only smoke run; a long-form spelling of
#                               SKIP_PIN_RESOLUTION=1 so callers that pass
#                               flags (rather than env) read honestly (still
#                               exit 2 if no parser)
#        SKIP_PIN_RESOLUTION=1  parse-only smoke run (still exit 2 if no parser)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/yaml.sh
. "$SCRIPT_DIR/lib/yaml.sh"

OFFLINE_FLAG=0
ROOT=""
for a in "$@"; do
  case "$a" in
    --offline) OFFLINE_FLAG=1 ;;
    *) [ -z "$ROOT" ] && ROOT="$a" ;;
  esac
done
[ -n "$ROOT" ] || ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK="$ROOT/.github/workflows/actions.lock"

if [ ! -f "$LOCK" ]; then
  printf 'lock-pins: no actions.lock under %s — nothing recorded, nothing to resolve\n' "$ROOT"
  exit 0
fi

lock_json="$(yaml_to_json "$LOCK")" || {
  printf 'E-INSTRUMENT: actions.lock did not resolve as YAML — NO CHECK WAS PERFORMED\n' >&2
  exit 2
}

dep_keys_raw="$(jq_read "$lock_json" -r '.dependencies // {} | keys[]')" || {
  printf 'E-INSTRUMENT: actions.lock has no readable .dependencies map — NO CHECK WAS PERFORMED\n' >&2
  exit 2
}
dep_keys=()
[ -n "$dep_keys_raw" ] && mapfile -t dep_keys <<< "$dep_keys_raw"

if [ "${#dep_keys[@]}" -eq 0 ]; then
  printf 'lock-pins: actions.lock records no dependencies — nothing to resolve\n'
  exit 0
fi

if [ "${SKIP_PIN_RESOLUTION:-0}" = "1" ] || [ "$OFFLINE_FLAG" = "1" ]; then
  printf 'lock-pins: parse-only run — examined %d dependency record(s), resolution skipped by request\n' "${#dep_keys[@]}"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  printf 'E-INSTRUMENT: gh is required to resolve pins — NO CHECK WAS PERFORMED\n' >&2
  exit 2
fi

# ── Resolve one commit, classifying the answer ─────────────────────────────
# Sets RESOLVE_VERDICT to ok | dead | unverified
resolve_commit() {
  local slug="$1" sha="$2" err code
  RESOLVE_VERDICT="unverified"
  RESOLVE_REASON=""

  if err="$(gh api "repos/$slug/commits/$sha" --jq .sha 2>&1 >/dev/null)"; then
    RESOLVE_VERDICT="ok"
    return 0
  fi

  code="$(printf '%s' "$err" | grep -oE 'HTTP [0-9]{3}' | grep -oE '[0-9]{3}' | head -1)"
  case "$code" in
    404 | 422)
      RESOLVE_VERDICT="dead"
      RESOLVE_REASON="GitHub answered $code for $slug@$sha"
      ;;
    403 | 429)
      RESOLVE_VERDICT="unverified"
      RESOLVE_REASON="rate limited or forbidden (HTTP $code) — says nothing about the pin"
      ;;
    "")
      RESOLVE_VERDICT="unverified"
      RESOLVE_REASON="no HTTP answer (network or CLI failure)"
      ;;
    *)
      RESOLVE_VERDICT="unverified"
      RESOLVE_REASON="indeterminate answer (HTTP $code)"
      ;;
  esac
  return 0
}

dead=0
unverified=0
resolved=0

printf 'lock-pins: resolving %d dependency record(s) against GitHub\n' "${#dep_keys[@]}"

for key in "${dep_keys[@]}"; do
  slug="${key%@*}"
  commit="$(jq_read "$lock_json" -r --arg k "$key" '.dependencies[$k].commit // ""')"

  if ! printf '%s' "$commit" | grep -qE '^sha1-[0-9a-f]{40}$'; then
    # Not an API question: the record itself is malformed, which is determinate.
    printf 'DEAD %s\n' "$key"
    printf '    no resolvable commit recorded (got: %s) — schema requires commit: sha1-<40 hex>\n' "${commit:-<absent>}"
    dead=$((dead + 1))
    continue
  fi

  sha="${commit#sha1-}"
  resolve_commit "$slug" "$sha"
  case "$RESOLVE_VERDICT" in
    ok)
      resolved=$((resolved + 1))
      ;;
    dead)
      printf 'DEAD %s\n' "$key"
      printf '    %s\n' "$RESOLVE_REASON"
      printf '    fix: re-point the workflow ref at a commit that exists, then regenerate the lock\n'
      dead=$((dead + 1))
      ;;
    unverified)
      printf 'UNVERIFIED %s\n' "$key"
      printf '    %s\n' "$RESOLVE_REASON"
      unverified=$((unverified + 1))
      ;;
  esac
done

printf 'lock-pins: resolved %d, dead %d, unverified %d (of %d)\n' \
  "$resolved" "$dead" "$unverified" "${#dep_keys[@]}"

if [ "$dead" -ne 0 ]; then
  printf 'lock-pins: %d determinately dead pin(s) — an unresolvable ref creates no check run at all\n' "$dead" >&2
  exit 1
fi
if [ "$unverified" -ne 0 ]; then
  # Never say "every pin resolves" when some were not examined. The count of
  # examined pins is the verdict; the rest is an announced gap, not a pass.
  printf 'lock-pins: PASS on the %d pin(s) GitHub answered for; %d pin(s) NOT EXAMINED\n' \
    "$resolved" "$unverified" >&2
  printf 'lock-pins: the unexamined pins carry no verdict — re-run when GitHub answers\n' >&2
  exit 0
fi
printf 'lock-pins: every recorded pin resolves\n'
exit 0
