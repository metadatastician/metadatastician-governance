#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Property-based cover for the ref normalisation in scripts/lib/yaml.sh.
#
# ── Why this is not another example test ───────────────────────────────────
#
# `tests/yaml-reader-test.sh` asserts `yaml_uses_in` against four hand-written
# fixtures: a job-level ref, a commented-out ref, a sub-path ref and a local
# ref. Those are the four shapes that have already bitten the estate. They say
# nothing about the shapes that have not bitten it yet, and TEST-NEEDS.adoc
# records category 9 (property-based) as THIN for exactly that reason: "several
# examples per declared defect class, no quantified coverage of the input
# space".
#
# This file closes that gap for one function by *generating* the input space
# from a grammar and asserting properties that must hold for every generated
# document, instead of equality against one hand-written expected list:
#
#   P1 SHAPE       every emitted ref is `OWNER/REPO@REF` — exactly one slash
#                  before the `@`, so no sub-path survived normalisation
#   P2 REF-INTACT  normalisation never rewrites the ref: the text after `@` is
#                  byte-identical to a ref the document actually asked for. A
#                  reader that "helpfully" narrowed `v4` to `v4.2.1` fails here;
#                  that is the reader-side twin of the pin drift which killed
#                  this repository's sweep for four days.
#   P3 COMPLETE    every external ref in the document is emitted (nothing lost)
#   P4 NO-EXTRAS   nothing else is emitted — commented-out refs, `./…` local
#                  refs, `$/…` same-repo refs, `docker://…` container refs and
#                  ref-shaped text inside a `run:` string are all absent
#   P5 UNIQUE      no duplicates, however much the document repeats a ref
#   P6 DETERMINISM the same document read twice yields identical output
#   P7 NO-PARSER   with the parser withheld, every generated document yields
#                  exit 2 and EMPTY stdout — never an empty ref list, which a
#                  caller reads as "this workflow pins nothing"
#   P8 UNPARSEABLE a generated document then corrupted at random yields exit 2
#                  and no ref list — never a verdict on evidence not read
#
# P7 and P8 are the two ways this reader can fake a verdict. Both were asserted
# once each on hand-written input; both are now quantified over generated input.
#
# ── Reproducibility and shrinking ──────────────────────────────────────────
#
# Generation is seeded (`SEED=<n>` overrides; the seed is printed), so a failure
# reproduces byte for byte. Cases are generated small on purpose — at most
# `REFS_PER_CASE` refs plus one job-level call — so a failing case is already
# near-minimal, and the whole document is printed with its expected and emitted
# sets. For the properties evaluable without ground truth (P1 SHAPE, P5 UNIQUE)
# the case is additionally shrunk: `uses:` lines are dropped one at a time from
# the end for as long as the violation persists, and the smallest violating
# document is printed. P3/P4 need ground truth to evaluate, so they cannot be
# shrunk without regenerating it; for those the case is printed whole and the
# differing lines are named.
#
# ── Two generator bugs this file has already paid for, recorded so they are
#    not reintroduced ───────────────────────────────────────────────────────
#
# 1. Randomness drawn inside a command substitution does not advance the
#    parent's PRNG: `owner=$(pick OWNERS); repo=$(pick REPOS)` gave every array
#    the SAME index, so the "universe" was one correlated diagonal of the input
#    space and the case count overstated the coverage. All draws here go
#    through `pick_into`, which assigns with `printf -v` and therefore consumes
#    a draw in the parent shell.
# 2. The exclusion prefixes were generated only WITHOUT a trailing `@ref`, so
#    `select(contains("@"))` dropped them before the prefix filter was ever
#    reached — deleting the prefix filter changed nothing and the mutant
#    survived. `LOCALS_WITH_REF` exists for that reason, and the negative
#    controls below are built from fixed corpora rather than from whatever the
#    PRNG happened to produce, so a control can never pass by luck.
#
# ── Exit contract ──────────────────────────────────────────────────────────
#   0 = every property held for every generated case, and every constructed
#       mutant broke at least one of them
#   1 = a property was violated, or a mutant that should have been caught was
#       not (seed, case, expected/emitted and the shrunk reproducer on stdout)
#   2 = NO CHECK WAS PERFORMED — no YAML parser, or a negative control whose
#       clause is no longer present in the reader, so this test can no longer
#       demonstrate its own discriminating power. Deliberately NOT the
#       SKIP-and-exit-0 shape the example tests use: a pass that reports
#       nothing must not look like a pass. A parser is present on the runner —
#       Lock Sync Gate run 36361142025 on main concluded `success`, and
#       scripts/check-lock-sync.sh can only reach 0 through this reader.
#
# Usage: [SEED=n] [CASES=n] [REFS_PER_CASE=n] tests/ref-normalisation-property-test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
READER="$ROOT/scripts/lib/yaml.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

SEED="${SEED:-20260928}"
CASES="${CASES:-40}"
REFS_PER_CASE="${REFS_PER_CASE:-6}"

pass=0
violations=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; violations=$((violations + 1)); }

# ── instrument check: no parser means no score, and that is exit 2 ─────────
kind="$(bash -c ". '$READER'; yaml_parser_kind")"
if [ "$kind" = "none" ]; then
  echo "ref-normalisation-property-test: no YAML parser available (tried yq, ruby, python3+pyyaml)" >&2
  echo "ref-normalisation-property-test: NO CHECK WAS PERFORMED — no property was evaluated, so there is no score" >&2
  exit 2
fi
echo "ref-normalisation-property-test: parser=$kind seed=$SEED cases=$CASES refs/case=$REFS_PER_CASE"

# ── the generator's alphabet ───────────────────────────────────────────────
# Deliberately inside what GitHub allows and what YAML can carry in single
# quotes. An owner cannot contain ':' (the reader's slug pattern excludes it),
# a ref cannot contain '@' ("the text after @" would stop being well defined),
# and sub-path segments are plain path elements.
OWNERS=(actions github hyperpolymath ossf metadatastician my-org)
REPOS=(checkout codeql-action setup-node scorecard-action gh-actions-lock repo.with.dots)
SUBPATHS=("" "/init" "/analyze" "/.github/workflows/scorecard-reusable.yml" "/action.yml" "/dist/sub/dir")
# Generator data, not repository state: these refs are combined with OWNERS,
# REPOS and SUBPATHS to synthesise documents for the reader to parse. None is
# resolved against GitHub and none is asserted to be in use. `892497fe…` is a pin
# this repository retired on 2026-09-28 (see docs/governance/CI-CD-COVERAGE.adoc)
# and stays in the list because a bare 40-hex SHA is a shape the properties must
# cover; the tag/branch-ish entries (`v4`, `main`, `canary-2026`, `0.1.6`) exist
# to catch a normaliser that only handles SHAs.
REFS=(
  3d3c42e5aac5ba805825da76410c181273ba90b1
  1c5b675653bb5c22dbe9b12b556ec555138e09fd
  892497fe373744874316710966b81ae6f0ea9e66
  v7.0.1 v4 v4.2.1 v1.24.1 main canary-2026 rel_2026.09.01 0.1.6
)
LOCALS=("./.github/actions/composite" "$/actions/same-repo" "./action.yml")
LOCALS_WITH_REF=(
  "./.github/actions/composite@3d3c42e5aac5ba805825da76410c181273ba90b1"
  "$/actions/same-repo@v7.0.1"
  "./action.yml@v4.2.1"
)
DOCKER_REFS=(
  "docker://alpine:3.20"
  "docker://ghcr.io/hyperpolymath/oikos:latest"
  "docker://alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
)

# pick_into <var> <array-name> — assign one element, consuming a draw IN THE
# PARENT SHELL. Never wrap this in $(…): a subshell's RANDOM does not advance
# the parent's, which silently collapses the generated universe.
pick_into() {
  local -n _arr="$2"
  printf -v "$1" '%s' "${_arr[$((RANDOM % ${#_arr[@]}))]}"
}

ref_is_known() { # ref_is_known <text> — member of the generated ref alphabet?
  local candidate="$1" r
  for r in "${REFS[@]}"; do
    [ "$r" = "$candidate" ] && return 0
  done
  return 1
}

RANDOM="$SEED"

# ── one generated case ─────────────────────────────────────────────────────
# Writes the document to $1 and the expected normalised output (sorted, unique,
# one per line) to $2. Ground truth is known by construction — that is what
# makes these properties rather than a snapshot comparison.
gen_case() {
  local doc="$1" expected="$2" i owner repo sub ref kind2 line
  : > "$expected"
  {
    printf 'name: generated\non: [push]\njobs:\n'
    # A job-level reusable call in about half the cases: the shape the estate's
    # lockfile extractor went blind on.
    if [ $((RANDOM % 2)) -eq 0 ]; then
      pick_into owner OWNERS; pick_into repo REPOS; pick_into sub SUBPATHS; pick_into ref REFS
      [ -n "$sub" ] || sub="/.github/workflows/reusable.yml"
      printf '  joblevel:\n    uses: %s/%s%s@%s\n' "$owner" "$repo" "$sub" "$ref"
      printf '%s/%s@%s\n' "$owner" "$repo" "$ref" >> "$expected"
    fi
    printf '  build:\n    runs-on: ubuntu-latest\n    steps:\n'
    for i in $(seq 1 "$REFS_PER_CASE"); do
      case $((RANDOM % 5)) in
        0|1|2) # an ordinary external ref at step level
          pick_into owner OWNERS; pick_into repo REPOS; pick_into sub SUBPATHS; pick_into ref REFS
          printf '      - name: step %d\n        uses: %s/%s%s@%s\n' "$i" "$owner" "$repo" "$sub" "$ref"
          printf '%s/%s@%s\n' "$owner" "$repo" "$ref" >> "$expected"
          ;;
        3) # something that must NOT be read as a ref
          pick_into kind2 KINDS
          case "$kind2" in
            commented)
              pick_into owner OWNERS; pick_into repo REPOS; pick_into ref REFS
              printf '      # - uses: %s/%s@%s\n' "$owner" "$repo" "$ref"
              ;;
            container)   pick_into line DOCKER_REFS;      printf '      - uses: %s\n' "$line" ;;
            localref)    pick_into line LOCALS_WITH_REF;  printf '      - uses: %s\n' "$line" ;;
            localplain)  pick_into line LOCALS;           printf '      - uses: %s\n' "$line" ;;
            runtext)
              pick_into owner OWNERS; pick_into repo REPOS; pick_into ref REFS
              printf '      - run: echo %s/%s@%s is only text here\n' "$owner" "$repo" "$ref"
              ;;
          esac
          ;;
        4) # the same ref twice — uniqueness must survive repetition
          pick_into owner OWNERS; pick_into repo REPOS; pick_into sub SUBPATHS; pick_into ref REFS
          printf '      - uses: %s/%s%s@%s\n' "$owner" "$repo" "$sub" "$ref"
          printf '      - uses: %s/%s%s@%s\n' "$owner" "$repo" "$sub" "$ref"
          printf '%s/%s@%s\n' "$owner" "$repo" "$ref" >> "$expected"
          ;;
      esac
    done
  } > "$doc"
  sort -u "$expected" -o "$expected"
}
KINDS=(commented container localref localplain runtext)

# corrupt <doc> — make a parseable document unparseable, at random.
# Both operators are illegal YAML rather than merely unusual: an unclosed flow
# sequence, and a tab in indentation position (tabs may not indent, in any YAML
# version). Comment lines are skipped as tab targets, because a tab before a
# comment is not reliably an error.
corrupt() {
  local doc="$1" n line tab
  tab="$(printf '\t')"
  if [ $((RANDOM % 2)) -eq 0 ]; then
    printf '  bad_indent: [\n' >> "$doc"
    return 0
  fi
  n="$(grep -c '^[[:space:]]*[^#[:space:]]' "$doc")"
  if [ "${n:-0}" -eq 0 ]; then
    printf '  bad_indent: [\n' >> "$doc"
    return 0
  fi
  line="$(grep -n '^[[:space:]]*[^#[:space:]]' "$doc" | cut -d: -f1 | sed -n "$(( (RANDOM % n) + 1 ))p")"
  sed -i "${line}s/^/${tab}/" "$doc"
}

read_refs() { # read_refs <doc> [lib] — stdout is the reader's output, rc propagates
  local doc="$1" lib="${2:-$READER}"
  bash -c ". '$lib'; yaml_uses_in '$doc'"
}

# shape_violations <doc> [lib] — emitted refs that are not OWNER/REPO@REF, plus
# duplicates. Evaluable without ground truth, so it is what shrinking uses.
shape_violations() {
  local doc="$1" lib="${2:-$READER}" out bad_shape dupes
  out="$(read_refs "$doc" "$lib" 2>/dev/null)" || return 0
  bad_shape="$(printf '%s\n' "$out" | sed '/^$/d' | grep -cvE '^[^/@:]+/[^/@]+@[^@]+$')"
  dupes="$(printf '%s\n' "$out" | sed '/^$/d' | sort | uniq -d | wc -l)"
  printf '%s' "$(( ${bad_shape:-0} + ${dupes:-0} ))"
}

# violations_for <doc> <expected> [lib] — property violation count for one
# document against its ground truth.
violations_for() {
  local doc="$1" exp="$2" lib="${3:-$READER}" got out rc v=0 r
  got="$TMP/violations-$$.got"
  out="$(read_refs "$doc" "$lib" 2>/dev/null)"; rc=$?
  printf '%s\n' "$out" | sed '/^$/d' | sort -u > "$got"
  [ "$rc" -ne 0 ] && v=$((v + 1))
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    printf '%s' "$r" | grep -qE '^[^/@:]+/[^/@]+@[^@]+$' || v=$((v + 1))
    ref_is_known "${r##*@}" || v=$((v + 1))
  done < "$got"
  v=$(( v + $(comm -23 "$exp" "$got" | wc -l) ))   # P3 COMPLETE
  v=$(( v + $(comm -13 "$exp" "$got" | wc -l) ))   # P4 NO-EXTRAS
  v=$(( v + $(printf '%s\n' "$out" | sed '/^$/d' | sort | uniq -d | wc -l) ))  # P5 UNIQUE
  rm -f "$got"
  printf '%s' "$v"
}

checked_refs=0
for c in $(seq 1 "$CASES"); do
  doc="$TMP/case-$c.yml"
  exp="$TMP/case-$c.expected"
  gen_case "$doc" "$exp"

  out="$(read_refs "$doc" 2>"$TMP/err")"; rc=$?
  got="$TMP/case-$c.got"
  printf '%s\n' "$out" | sed '/^$/d' | sort -u > "$got"

  case_violations=0
  note_case_bad() { case_violations=$((case_violations + 1)); }

  if [ "$rc" -ne 0 ]; then
    bad "case $c: reader returned rc=$rc on a parseable document; stderr: $(head -2 "$TMP/err" | tr '\n' ' ')"
    note_case_bad
  fi

  # P1 SHAPE and P2 REF-INTACT
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    checked_refs=$((checked_refs + 1))
    if ! printf '%s' "$r" | grep -qE '^[^/@:]+/[^/@]+@[^@]+$'; then
      bad "case $c P1 SHAPE: emitted '$r', which is not OWNER/REPO@REF"
      note_case_bad
    elif ! ref_is_known "${r##*@}"; then
      bad "case $c P2 REF-INTACT: emitted ref '${r##*@}' is not a ref the document asked for (normalisation rewrote it)"
      note_case_bad
    fi
  done < "$got"

  # P3 COMPLETE
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    if ! grep -qxF "$want" "$got"; then
      bad "case $c P3 COMPLETE: '$want' was requested but not emitted"
      note_case_bad
    fi
  done < "$exp"

  # P4 NO-EXTRAS
  while IFS= read -r have; do
    [ -n "$have" ] || continue
    if ! grep -qxF "$have" "$exp"; then
      bad "case $c P4 NO-EXTRAS: '$have' was emitted but never requested (a comment, a local ref, a container ref or a run: string leaked)"
      note_case_bad
    fi
  done < "$got"

  # P5 UNIQUE — on the raw output, which is what callers consume
  dupes="$(printf '%s\n' "$out" | sed '/^$/d' | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    bad "case $c P5 UNIQUE: duplicate refs emitted: $(printf '%s' "$dupes" | tr '\n' ' ')"
    note_case_bad
  fi

  # P6 DETERMINISM
  out2="$(read_refs "$doc" 2>/dev/null)"
  if [ "$out" != "$out2" ]; then
    bad "case $c P6 DETERMINISM: two reads of the same document differ"
    note_case_bad
  fi

  # P7 NO-PARSER — exit 2 and empty stdout, for every generated document
  noparser_out="$(bash -c "YAML_PARSER_KIND=none; . '$READER'; yaml_uses_in '$doc'" 2>/dev/null)"
  noparser_rc=$?
  if [ "$noparser_rc" -ne 2 ] || [ -n "$noparser_out" ]; then
    bad "case $c P7 NO-PARSER: rc=$noparser_rc stdout='${noparser_out}' (want rc=2 and empty stdout)"
    note_case_bad
  fi

  # P8 UNPARSEABLE — corrupt this case at random, require exit 2 and no refs
  cdoc="$TMP/case-$c-corrupt.yml"
  cp "$doc" "$cdoc"
  corrupt "$cdoc"
  corrupt_out="$(read_refs "$cdoc" 2>/dev/null)"; corrupt_rc=$?
  if [ "$corrupt_rc" -ne 2 ]; then
    bad "case $c P8 UNPARSEABLE: corrupted document returned rc=$corrupt_rc (want 2)"
    note_case_bad
  fi
  if [ -n "$corrupt_out" ]; then
    bad "case $c P8 UNPARSEABLE: a corrupted document produced a ref list: '${corrupt_out}'"
    note_case_bad
  fi

  if [ "$case_violations" -eq 0 ]; then
    pass=$((pass + 1))
    continue
  fi

  # ── report, then shrink what can be shrunk ───────────────────────────────
  echo "  --- case $c: generated document ---"
  sed 's/^/    | /' "$doc"
  echo "  --- expected (ground truth by construction) ---"
  sed 's/^/    = /' "$exp"
  echo "  --- emitted ---"
  sed 's/^/    > /' "$got"
  if [ "$(shape_violations "$doc")" -gt 0 ]; then
    smallest="$doc"
    while :; do
      trial="$TMP/shrink-$c.yml"
      awk '{ lines[NR] = $0 }
           END { for (i = NR; i >= 1; i--) { if (!dropped && lines[i] ~ /uses:/) { dropped = 1; continue } print lines[i] } }' \
        "$smallest" > "$trial"
      [ -s "$trial" ] || break
      cmp -s "$trial" "$smallest" && break
      [ "$(shape_violations "$trial")" -gt 0 ] || break
      smallest="$trial"
    done
    echo "  --- smallest document that still violates P1/P5 ---"
    sed 's/^/    ! /' "$smallest"
    echo "  --- what it emits ---"
    read_refs "$smallest" 2>&1 | sed 's/^/    > /'
  fi
done

# ── Negative controls: this test must be able to fail ──────────────────────
#
# A property test whose properties no property-violating reader could break is
# decoration, and the estate's Test Doctrine says so explicitly: the harness
# must never fire on clean input, and the payload must always fire on a member
# of its declared class.
#
# Each control mutates scripts/lib/yaml.sh by deleting exactly one clause of
# the jq pipeline, then runs the mutant against a FIXED corpus built to contain
# the shape that clause is responsible for. Fixed, not generated: a control
# that depends on the PRNG having happened to produce the shape can pass by
# luck, and this file already had one that did.
#
# Two outcomes are refused:
#   * the clause is no longer in the reader, so the mutant cannot be built ->
#     exit 2, NO CHECK WAS PERFORMED (this test would otherwise keep claiming
#     coverage of code that no longer exists);
#   * the mutant is built and violates nothing -> the property is too weak to
#     notice the defect it names -> failure.
nc_dir="$TMP/controls"
mkdir -p "$nc_dir"

cat > "$nc_dir/prefix.yml" <<'YAML'
name: control — exclusion prefixes
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/composite@3d3c42e5aac5ba805825da76410c181273ba90b1
      - uses: $/actions/same-repo@v7.0.1
      - uses: docker://alpine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      - uses: actions/checkout@v7.0.1
YAML
printf 'actions/checkout@v7.0.1\n' > "$nc_dir/prefix.expected"

cat > "$nc_dir/subpath.yml" <<'YAML'
name: control — sub-path normalisation
on: [push]
jobs:
  joblevel:
    uses: hyperpolymath/standards/.github/workflows/scorecard-reusable.yml@892497fe373744874316710966b81ae6f0ea9e66
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: github/codeql-action/init@1c5b675653bb5c22dbe9b12b556ec555138e09fd
      - uses: github/codeql-action/analyze@1c5b675653bb5c22dbe9b12b556ec555138e09fd
YAML
printf 'github/codeql-action@1c5b675653bb5c22dbe9b12b556ec555138e09fd\nhyperpolymath/standards@892497fe373744874316710966b81ae6f0ea9e66\n' \
  | sort -u > "$nc_dir/subpath.expected"

cat > "$nc_dir/duplicate.yml" <<'YAML'
name: control — uniqueness
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7.0.1
      - uses: actions/checkout@v7.0.1
      - name: and again, with a sub-path this time
        uses: actions/checkout/dist/index.js@v7.0.1
YAML
printf 'actions/checkout@v7.0.1\n' > "$nc_dir/duplicate.expected"

build_mutant() { # build_mutant <name> <literal clause to delete> -> path, or rc 2
  # Two statements: `local` expands all its words before assigning any, so
  # dir="$TMP/mutant-$name" on the same line would read the CALLER'S `name`
  # through dynamic scoping — or fail outright under set -u.
  local name="$1" needle="$2"
  local dir="$TMP/mutant-$name"
  mkdir -p "$dir"
  cp "$READER" "$dir/yaml.sh"
  grep -qF "$needle" "$dir/yaml.sh" || return 2
  grep -vF "$needle" "$dir/yaml.sh" > "$dir/yaml.sh.new" || return 2
  mv "$dir/yaml.sh.new" "$dir/yaml.sh"
  cmp -s "$dir/yaml.sh" "$READER" && return 2
  printf '%s' "$dir/yaml.sh"
}

# The harness must never fire on clean input — asserted on the control corpora
# too, not only on the generated cases.
for ctl in prefix subpath duplicate; do
  v="$(violations_for "$nc_dir/$ctl.yml" "$nc_dir/$ctl.expected")"
  if [ "$v" -eq 0 ]; then
    ok "control corpus '$ctl': the real reader satisfies every property on it"
  else
    bad "control corpus '$ctl': the REAL reader violates $v propert(y/ies) — the corpus or its ground truth is wrong"
  fi
done

controls_run=0
controls_fired=0
run_control() { # run_control <name> <clause> <corpus> <property it must break>
  local name="$1" clause="$2" corpus="$3" prop="$4" lib v
  if ! lib="$(build_mutant "$name" "$clause")"; then
    echo "  FAIL negative control '$name': the clause this test mutates is no longer in scripts/lib/yaml.sh" >&2
    echo "       clause: $clause" >&2
    echo "       NO CHECK WAS PERFORMED for this control — update it to the current reader" >&2
    violations=$((violations + 1))
    return 2
  fi
  controls_run=$((controls_run + 1))
  v="$(violations_for "$nc_dir/$corpus.yml" "$nc_dir/$corpus.expected" "$lib")"
  if [ "$v" -gt 0 ]; then
    ok "negative control '$name': mutant killed — $v property violation(s) on the fixed corpus, so $prop is load-bearing"
    controls_fired=$((controls_fired + 1))
    echo "       what the mutant emitted: $(read_refs "$nc_dir/$corpus.yml" "$lib" 2>/dev/null | tr '\n' ' ')"
  else
    bad "negative control '$name': deleting '$clause' broke NO property — $prop does not actually cover it"
  fi
}

run_control prefix-filter \
  'map(select((startswith("./") or startswith("$/") or startswith("docker://")) | not))' \
  prefix 'P4 NO-EXTRAS'
run_control subpath-normalisation \
  'map(sub("^(?<slug>[^/]+/[^/@]+)(/[^@]*)?@"; "\(.slug)@"))' \
  subpath 'P1 SHAPE'
run_control uniqueness '| unique' duplicate 'P5 UNIQUE'

echo
echo "ref-normalisation-property-test: $CASES generated document(s), $checked_refs emitted ref(s), 8 properties"
echo "ref-normalisation-property-test: negative controls — $controls_fired of $controls_run constructed mutant(s) killed by the properties"
if [ "$violations" -ne 0 ] || [ "$controls_fired" -ne "$controls_run" ] || [ "$controls_run" -ne 3 ]; then
  echo "ref-normalisation-property-test: $violations violation(s); $pass case/property pass(es) — reproduce with SEED=$SEED" >&2
  if [ "$controls_run" -ne 3 ]; then
    echo "ref-normalisation-property-test: only $controls_run of 3 mutants could be constructed — NO CHECK WAS PERFORMED for the rest" >&2
    exit 2
  fi
  exit 1
fi
echo "ref-normalisation-property-test: all 8 properties held for all $CASES generated case(s), and every mutant broke one"
exit 0
