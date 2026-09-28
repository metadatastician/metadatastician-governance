#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# kyaml-census.sh — what would the KYAML migration actually have to convert,
# and what would it risk destroying?
#
# ── Why this exists ────────────────────────────────────────────────────────
#
# `hyperpolymath/standards` 3-practice/YAML-POLICY.adoc rule Y-3 makes KYAML the
# target authoring dialect but deliberately does NOT mandate it yet. Scope is
# undecided (step 4, standards#1023) and the migration steps are sequenced:
#
#   step 2 #1021  comment-preservation proof   ← blocks Y-2 and Y-3 alike
#   step 3 #1022  a formatter/linter for arbitrary YAML
#   step 4 #1023  owner ruling on scope
#   step 5 #1024  migrate estate-authored non-bot YAML
#   step 6 #1025  workflows, only if step 4 rules them in
#
# Nothing in the estate is out of compliance with Y-3 today, because Y-3
# imposes nothing today. This script does not convert anything and must never
# be wired into a gate that does. `yq -i` and every other blind rewrite are
# forbidden until the step-2 proof lands (Y-2 §2.2).
#
# What it does is produce the *inventory the migration will need*: which files
# are in scope for which step, which are tool-owned and must never be
# reformatted, and how many load-bearing comments are at risk. That number is
# the whole argument of Y-2 §2.1 — the tag in
# `uses: actions/checkout@3d3c42e5… # v7.0.1` is the only thing that makes the
# pin reviewable, and losing it is a silent, estate-wide degradation that no
# parse check would catch.
#
# ── Reading rule boundary (Y-1) ────────────────────────────────────────────
#
# "Does this file parse as YAML" is asked of a real parser (`scripts/lib/
# yaml.sh`, `yq` first) — never of a line reader.
#
# "How many comment lines does this file carry" cannot be asked of a parser:
# comments are not part of the document, and every YAML parser discards them.
# That count is therefore a scan of the file as text, and it is labelled as one
# in the output. This is the stated edge of Y-1, not an exception to it: Y-1
# governs obtaining *values* out of a YAML document, and a comment is not a
# value. Do not grow this exception — if a value is wanted, use the parser.
#
# ── Exit contract ──────────────────────────────────────────────────────────
#   0 = census produced
#   2 = NO CENSUS PERFORMED — no parser available
#
# Usage: kyaml-census.sh [REPO_ROOT] [--tsv]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/yaml.sh
. "$SCRIPT_DIR/lib/yaml.sh"

ROOT="."
TSV=0
for a in "$@"; do
  case "$a" in
    --tsv) TSV=1 ;;
    *) ROOT="$a" ;;
  esac
done
ROOT="$(cd "$ROOT" && pwd)"

kind="$(yaml_parser_kind)"
if [ "$kind" = "none" ]; then
  printf 'E-INSTRUMENT: no YAML parser (yq/ruby/nickel/python) — NO CENSUS WAS PERFORMED\n' >&2
  exit 2
fi

[ "$TSV" -eq 1 ] && printf 'ownership\tscope-step\tparses\tcomments\tfile\n'
[ "$TSV" -eq 1 ] || printf 'kyaml-census: parser=%s root=%s\n' "$kind" "$ROOT" 

# Enumerate tracked YAML. git ls-files keeps node_modules/target/vendor out for
# free and gives a population we can state.
mapfile -t files < <(
  cd "$ROOT" &&
    { git ls-files -z -- '*.yml' '*.yaml'; printf '%s\0' '.github/workflows/actions.lock'; } |
    tr '\0' '\n' | grep -v '^$' | sort -u
)

if [ "${#files[@]}" -eq 0 ]; then
  [ "$TSV" -eq 1 ] || printf 'kyaml-census: no tracked YAML files — nothing in scope\n'
  exit 0
fi

tool_owned=0
bot_written=0
estate_authored=0
unparseable=0
comments_total=0

missing=0
for rel in "${files[@]}"; do
  file="$ROOT/$rel"

  # Tracked but absent from the working tree (a deletion not yet committed, or
  # a sparse checkout). Say so rather than reporting it as unparseable.
  if [ ! -f "$file" ]; then
    missing=$((missing + 1))
    [ "$TSV" -eq 1 ] || printf '  %-15s %-26s %s\n' "missing" "not in working tree" "$rel"
    continue
  fi

  # Ownership. Tool-owned artefacts are out of scope for every step: YAML-POLICY
  # §6 says lockfiles "must never be hand-edited or reformatted", and workflow
  # YAML is written by Dependabot and `gh actions-lock` (§0 measurement: 9,261
  # files, written by bots). Step 6 additionally requires that Dependabot and
  # `gh actions-lock` either emit KYAML or their drift is accepted in writing.
  case "$rel" in
    .github/workflows/actions.lock | */actions.lock)
      owner="tool-owned"
      step="excluded (lockfile)"
      ;;
    .github/workflows/*)
      owner="bot-rewritten"
      step="step-6 (#1025, gated on #1023)"
      ;;
    .github/*)
      owner="estate-authored"
      step="step-5 (#1024)"
      ;;
    *)
      owner="estate-authored"
      step="step-5 (#1024)"
      ;;
  esac

  case "$owner" in
    tool-owned) tool_owned=$((tool_owned + 1)) ;;
    bot-rewritten) bot_written=$((bot_written + 1)) ;;
    *) estate_authored=$((estate_authored + 1)) ;;
  esac

  # Parses? Asked of the parser.
  if yaml_to_json "$file" >/dev/null 2>&1; then
    parses="yes"
  else
    parses="NO"
    unparseable=$((unparseable + 1))
  fi

  # Comment lines. Text scan by necessity — labelled as such above.
  comments="$(grep -cE '^[[:space:]]*#' "$file" 2>/dev/null || true)"
  [ -n "$comments" ] || comments=0
  comments_total=$((comments_total + comments))

  if [ "$TSV" -eq 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\n' "$owner" "$step" "$parses" "$comments" "$rel"
  else
    printf '  %-15s %-26s parses=%-3s comments=%-3s %s\n' \
      "$owner" "$step" "$parses" "$comments" "$rel"
  fi
done

if [ "$TSV" -eq 1 ]; then
  exit 0
fi

cat <<EOF

kyaml-census: ${#files[@]} tracked YAML file(s), parser=${kind}
  bot-rewritten, step 6 (#1025)  ${bot_written}
  estate-authored, step 5 (#1024) ${estate_authored}
  tool-owned, excluded            ${tool_owned}
  do not parse today              ${unparseable}
  not in working tree             ${missing}
  comment lines at risk           ${comments_total}

  Nothing here is out of compliance: Y-3 imposes nothing today, and this census
  converts nothing. The migration steps are hyperpolymath/standards #1021-#1025,
  and Y-2/Y-3 both require the comment-preservation proof (#1021) before any
  rewrite tool is allowed near these files. ${comments_total} comment line(s)
  is the population that proof has to preserve.
EOF
