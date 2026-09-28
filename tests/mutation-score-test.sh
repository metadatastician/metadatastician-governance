#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# mutation-score-test.sh — a SCORED mutation pass over the gate fixtures.
#
# ── What was missing, and what this adds ───────────────────────────────────
#
# Every gate in this repository already ships a firing fixture, and
# `tests/lock-sync-test.sh` / `tests/lock-pins-test.sh` require it to fire. That
# is a real assertion but it is not a score: it says "this one member of this
# one class is detected", and TEST-NEEDS.adoc records category 10 (mutation) as
# THIN for exactly that reason — "these are input mutants, not code mutants, and
# there is no mutation-score tool".
#
# This file produces a number, in both directions, and fails if the number moves:
#
#   PART A — input mutation (the fixtures are the mutants).
#     A catalogue of fixture mutations, each declared as a member of a class the
#     gate says it detects, or as a benign variant the gate says it must NOT
#     call drift. Two scores fall out:
#       DETECTION  = killed / should-be-killed
#       SPECIFICITY = spared / should-be-spared
#     "Killed" means the gate returned the exact declared exit code. A gate that
#     answers 2 (NO CHECK WAS PERFORMED) when 1 (drift found) was declared is
#     recorded as WRONG-CODE, not as a kill: an instrument failure that happens
#     to be non-zero is not a detection, and counting it as one is how a suite
#     reports a score it did not earn.
#
#   PART B — code mutation (the gates are the mutants).
#     A catalogue of single-line mutations of the gate code itself, each of which
#     removes or inverts a decision the gate documents. Each mutant is run
#     against the WHOLE Part A corpus, and is killed only if some corpus member's
#     verdict changes. This is mutation scoring in the textbook sense, and it is
#     the half that answers "would anyone notice if this check were deleted?".
#
# Part B is why Part A's benign mutants matter as much as its firing ones: the
# mutant that turns the coverage NOTE into a FAIL (C5) is caught only by a
# benign input, so a corpus of nothing but broken fixtures would score it as
# undetected.
#
# ── Exit contract ──────────────────────────────────────────────────────────
#   0 = every declared mutant was killed / spared as declared, and every code
#       mutant that could be constructed was killed by the corpus
#   1 = a mutant survived, was killed with the wrong exit code, or a benign
#       variant was called drift (the full table is on stdout, with the score)
#   2 = NO CHECK WAS PERFORMED — no YAML parser, or a code mutant whose anchor
#       line is no longer in the gate, so this file can no longer demonstrate
#       that the corpus notices its removal. Never reported as a pass.
#
# The `parse` family (scripts/check-workflows-parse.sh) is scored only where its
# own instruments exist — that upstream script accepts `yq` or `ruby` and no
# other parser. Where neither is installed the family is reported as NOT SCORED
# and excluded from both denominators, with the reason printed. Excluding it is
# honest; silently counting it as passed would not be.
#
# Usage: tests/mutation-score-test.sh        (MUTATION_VERBOSE=1 prints every verdict)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_GATE="$ROOT/scripts/check-lock-sync.sh"
PINS_GATE="$ROOT/scripts/check-lock-pins.sh"
PARSE_GATE="$ROOT/scripts/check-workflows-parse.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out"; ERR="$TMP/err"

VERBOSE="${MUTATION_VERBOSE:-0}"

pass=0
fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

# ── instrument check ───────────────────────────────────────────────────────
kind="$(bash -c ". '$ROOT/scripts/lib/yaml.sh'; yaml_parser_kind")"
if [ "$kind" = "none" ]; then
  echo "mutation-score-test: no YAML parser available (tried yq, ruby, python3+pyyaml)" >&2
  echo "mutation-score-test: NO CHECK WAS PERFORMED — no mutant was evaluated, so there is no score" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "mutation-score-test: jq is required to read parser output — NO CHECK WAS PERFORMED" >&2
  exit 2
fi
echo "mutation-score-test: parser=$kind"

PARSE_INSTRUMENT=""
if command -v yq >/dev/null 2>&1; then PARSE_INSTRUMENT="yq"
elif command -v ruby >/dev/null 2>&1; then PARSE_INSTRUMENT="ruby"
fi
if [ -n "$PARSE_INSTRUMENT" ]; then
  echo "mutation-score-test: check-workflows-parse.sh will be scored (instrument: $PARSE_INSTRUMENT)"
else
  echo "mutation-score-test: check-workflows-parse.sh NOT SCORED here — that upstream gate accepts only yq or ruby,"
  echo "                         and neither is installed. Its family is excluded from the score, not counted as passed."
fi

SHA=3d3c42e5aac5ba805825da76410c181273ba90b1
OTHER=1c5b675653bb5c22dbe9b12b556ec555138e09fd
TAGREF=v7.0.1
REUSABLE=hyperpolymath/standards/.github/workflows/governance-reusable.yml@892497fe373744874316710966b81ae6f0ea9e66
# These are FIXTURE constants, not the repository's pins: synthetic workflow
# documents are built from them so the gates have realistic ref shapes to read.
# Nothing here is resolved against GitHub, and nothing here asserts that any of
# these commits is in use. Two notes for a reader who arrives from the workflows:
# `892497fe…` is a pin this repository RETIRED on 2026-09-28 (it is not an
# ancestor of upstream main — see docs/governance/CI-CD-COVERAGE.adoc), and it is
# kept here deliberately, because a job-level reusable call at a 40-hex SHA is
# exactly the shape the parse fixtures must exercise and exactly the shape the
# lock tool's extractor is documented to miss. `3d3c42e5…` is the commit the lock
# records for `actions/checkout@v7.0.1`, which is what makes the S-family mutants
# about ref *strings* rather than about resolved commits — the distinction that
# caused the four-day sweep outage.

# ── the gh stub: pins must be scoreable offline and repeatably ─────────────
STUBBIN="$TMP/bin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
code="${STUB_CODE:-200}"
if [ "$code" = "200" ]; then
  printf '%s\n' '3d3c42e5aac5ba805825da76410c181273ba90b1'
  exit 0
fi
case "$code" in
  404) printf 'gh: Not Found (HTTP 404)\n' >&2 ;;
  422) printf 'gh: No commit found for SHA (HTTP 422)\n' >&2 ;;
  403) printf 'gh: API rate limit exceeded (HTTP 403)\n' >&2 ;;
  503) printf 'gh: Service Unavailable (HTTP 503)\n' >&2 ;;
  NETFAIL) printf 'gh: dial tcp: lookup api.github.com: no such host\n' >&2 ;;
esac
exit 1
STUB
chmod +x "$STUBBIN/gh"

# ── baselines ──────────────────────────────────────────────────────────────
# A consistent lock/YAML pair. Every mutant below is one declared edit of it, so
# a surviving mutant is a statement about the gate and not about the fixture.
new_sync_fixture() { # new_sync_fixture <name>
  local d="$TMP/fx-$1"
  rm -rf "$d"; mkdir -p "$d/.github/workflows"
  cat > "$d/.github/workflows/alpha.yml" <<YAML
name: alpha
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$SHA
YAML
  cat > "$d/.github/workflows/beta.yml" <<'YAML'
name: beta
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo nothing external here
YAML
  cat > "$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.2'
workflows:
    '.github/workflows/alpha.yml':
        - 'actions/checkout@$SHA'
    '.github/workflows/beta.yml': []
dependencies:
    'actions/checkout@$SHA':
        ref: '$SHA'
        commit: 'sha1-$SHA'
        owner_id: 44036562
        repo_id: 197814629
YAML
  printf '%s' "$d"
}

new_pins_fixture() { # new_pins_fixture <name> — two dependency records
  local d="$TMP/fx-$1"
  rm -rf "$d"; mkdir -p "$d/.github/workflows"
  : > "$d/.github/workflows/dummy.yml"
  cat > "$d/.github/workflows/actions.lock" <<YAML
version: 'v0.0.2'
workflows:
    '.github/workflows/dummy.yml':
        - 'actions/checkout@$SHA'
dependencies:
    'actions/checkout@$SHA':
        ref: '$SHA'
        commit: 'sha1-$SHA'
        owner_id: 44036562
        repo_id: 197814629
    'actions/setup-node@1111111111111111111111111111111111111111':
        ref: '1111111111111111111111111111111111111111'
        commit: 'sha1-1111111111111111111111111111111111111111'
        owner_id: 44036562
        repo_id: 194000000
YAML
  printf '%s' "$d"
}

new_parse_fixture() { # new_parse_fixture <name> — a git repo, because that gate enumerates with git ls-files
  local d="$TMP/fx-$1"
  rm -rf "$d"; mkdir -p "$d/.github/workflows"
  cat > "$d/.github/workflows/ok.yml" <<YAML
name: ok
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$SHA
YAML
  ( cd "$d" && git init -q . && git add -A >/dev/null 2>&1 )
  printf '%s' "$d"
}

# insert_after <file> <fixed-anchor> <line-to-insert>
insert_after() {
  awk -v anchor="$2" -v ins="$3" 'index($0, anchor) { print; print ins; next } { print }' "$1" > "$1.new" && mv "$1.new" "$1"
}

# ── PART A mutators: one declared edit each ────────────────────────────────
m_S1()  { printf '      - uses: actions/setup-node@%s\n' "$OTHER" >> "$1/.github/workflows/alpha.yml"; }
m_S2()  { insert_after "$1/.github/workflows/actions.lock" "- 'actions/checkout@$SHA'" "        - 'actions/setup-node@$OTHER'"; }
m_S3()  { insert_after "$1/.github/workflows/actions.lock" "'.github/workflows/beta.yml': []" "    '.github/workflows/deleted.yml': []"; }
m_S4()  { printf '      - uses: actions/setup-node@%s\n' "$OTHER" >> "$1/.github/workflows/alpha.yml"
          insert_after "$1/.github/workflows/actions.lock" "- 'actions/checkout@$SHA'" "        - 'actions/setup-node@$OTHER'"; }
m_S5()  { printf '      - uses: actions/setup-node@%s\n' "$OTHER" >> "$1/.github/workflows/alpha.yml"
          insert_after "$1/.github/workflows/actions.lock" "- 'actions/checkout@$SHA'" "        - 'actions/setup-node@$OTHER'"
          cat >> "$1/.github/workflows/actions.lock" <<YAML
    'actions/setup-node@$OTHER':
        ref: '$OTHER'
        commit: 'sha1-2222222222222222222222222222222222222222'
        owner_id: 44036562
        repo_id: 194000000
YAML
        }
m_S6()  { sed -i "s#        commit: 'sha1-$SHA'#        commit: 'not-a-sha1'#" "$1/.github/workflows/actions.lock"; }
m_S7()  { sed -i "/        commit: 'sha1-$SHA'/d" "$1/.github/workflows/actions.lock"; }
m_S8()  { sed -i "s#    'actions/checkout@$SHA':#    'actions/checkout/sub/path@$SHA':#" "$1/.github/workflows/actions.lock"; }
m_S9()  { cat >> "$1/.github/workflows/actions.lock" <<YAML
    'actions/setup-node@':
        ref: ''
        commit: 'sha1-$OTHER'
        owner_id: 44036562
        repo_id: 194000000
YAML
        }
m_S10() { cat >> "$1/.github/workflows/actions.lock" <<YAML
    'actions/setup-node@@$OTHER':
        ref: '$OTHER'
        commit: 'sha1-$OTHER'
        owner_id: 44036562
        repo_id: 194000000
YAML
        }
m_S11() { insert_after "$1/.github/workflows/actions.lock" "        repo_id: 197814629" "        uses:
            - 'actions/setup-node@$OTHER'"; }
m_S12() { insert_after "$1/.github/workflows/actions.lock" "workflows:" "    'not-a-workflow-path': []"; }
m_S13() { # THE INCIDENT: the workflow pins a SHA, the lock records the tag.
          sed -i "s#        - 'actions/checkout@$SHA'#        - 'actions/checkout@$TAGREF'#" "$1/.github/workflows/actions.lock"
          sed -i "s#    'actions/checkout@$SHA':#    'actions/checkout@$TAGREF':#" "$1/.github/workflows/actions.lock"
          sed -i "s#        ref: '$SHA'#        ref: '$TAGREF'#" "$1/.github/workflows/actions.lock"; }
m_S14() { # a job-level reusable call, invisible to a step-level-only extractor
          printf '  reusable:\n    uses: %s\n' "$REUSABLE" >> "$1/.github/workflows/alpha.yml"; }
m_S15() { printf 'jobs:\n  build:\n    steps:\n      - uses: actions/checkout@abc\n  bad: [\n' > "$1/.github/workflows/beta.yml"; }
m_S16() { printf '  bad_indent: [\n' >> "$1/.github/workflows/actions.lock"; }
m_S17() { rm -rf "$1/.github/workflows"; }
m_S18() { rm -f "$1"/.github/workflows/*.yml; }
m_S2b() { # a lock entry the workflow does not request, WITH a well-formed dependency
          # record for it, so the stale-direction comparison is the ONLY check that can
          # catch it. Added because code mutant C2 (stale detection deleted) survived
          # without it: S2 is caught twice over, and a corpus that only contains inputs
          # with redundant defects cannot tell you which decision does the work.
          insert_after "$1/.github/workflows/actions.lock" "- 'actions/checkout@$SHA'" "        - 'actions/setup-node@$OTHER'"
          cat >> "$1/.github/workflows/actions.lock" <<YAML
    'actions/setup-node@$OTHER':
        ref: '$OTHER'
        commit: 'sha1-$OTHER'
        owner_id: 44036562
        repo_id: 194000000
YAML
        }
m_S20() { # a TAG ref whose recorded commit is malformed. The SHA-agreement check cannot
          # fire on a tag, so the commit-format guard is the only thing standing between
          # this lock and a pin GitHub cannot resolve. Added for code mutant C3.
          cat > "$1/.github/workflows/alpha.yml" <<YAML
name: alpha
on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@$TAGREF
YAML
          cat > "$1/.github/workflows/actions.lock" <<YAML
version: 'v0.0.2'
workflows:
    '.github/workflows/alpha.yml':
        - 'actions/checkout@$TAGREF'
    '.github/workflows/beta.yml': []
dependencies:
    'actions/checkout@$TAGREF':
        ref: '$TAGREF'
        commit: 'not-a-sha1'
        owner_id: 44036562
        repo_id: 197814629
YAML
        }
m_B1()  { cat > "$1/.github/workflows/actions.lock" <<YAML
version: 'v0.0.2'
workflows: {'.github/workflows/alpha.yml': ['actions/checkout@$SHA'], '.github/workflows/beta.yml': []}
dependencies: {'actions/checkout@$SHA': {ref: '$SHA', commit: 'sha1-$SHA', owner_id: 44036562, repo_id: 197814629}}
YAML
        }
m_B2()  { insert_after "$1/.github/workflows/actions.lock" "version: 'v0.0.2'" "# a comment added by hand, carrying no fact"
          insert_after "$1/.github/workflows/actions.lock" "dependencies:" "    # every pin below was resolved on the day it was written"; }
m_B3()  { cat > "$1/.github/workflows/actions.lock" <<YAML
version: 'v0.0.2'
workflows:
    '.github/workflows/beta.yml': []
    '.github/workflows/alpha.yml':
        - 'actions/checkout@$SHA'
dependencies:
    'actions/checkout@$SHA':
        ref: '$SHA'
        commit: 'sha1-$SHA'
        owner_id: 44036562
        repo_id: 197814629
YAML
        }
m_B4()  { cat > "$1/.github/workflows/actions.lock" <<YAML
version: 'v0.0.2'
workflows:
    '.github/workflows/alpha.yml':
        - 'actions/checkout@$SHA'
    '.github/workflows/beta.yml': []
dependencies:
    'actions/checkout@$SHA':
        owner_id: 44036562
        repo_id: 197814629
        commit: 'sha1-$SHA'
        ref: '$SHA'
YAML
        }
m_B5()  { printf 'name: gamma\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo uses-free and unlisted\n' > "$1/.github/workflows/gamma.yml"; }
m_B6()  { printf 'name: gamma\non: [push]\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@%s\n' "$SHA" > "$1/.github/workflows/gamma.yml"; }
m_B7()  { rm -f "$1/.github/workflows/actions.lock"; }
m_B8()  { sed -i 's/^    /        /; s/^        - /            - /' "$1/.github/workflows/actions.lock"; }
m_B9()  { printf '      - uses: actions/checkout@%s\n' "$SHA" >> "$1/.github/workflows/alpha.yml"; }
m_B10() { printf '      - run: echo actions/setup-node@%s is text, not a ref\n' "$OTHER" >> "$1/.github/workflows/beta.yml"; }
m_B11() { printf '      # - uses: actions/setup-node@%s\n' "$OTHER" >> "$1/.github/workflows/alpha.yml"; }

m_P4()  { sed -i "s#        commit: 'sha1-1111111111111111111111111111111111111111'#        commit: 'not-a-sha1'#" "$1/.github/workflows/actions.lock"; }

m_W1()  { printf 'name: broken\non: [push]\njobs:\n  build:\n   bad: [\n' > "$1/.github/workflows/broken.yml"
          ( cd "$1" && git add -A >/dev/null 2>&1 ); }
m_W2()  { printf 'name: empty\non: [push]\njobs: {}\n' > "$1/.github/workflows/empty.yml"
          ( cd "$1" && git add -A >/dev/null 2>&1 ); }
m_W3()  { cat > "$1/.github/workflows/call.yml" <<YAML
name: call
on: [push]
jobs:
  delegated:
    uses: hyperpolymath/standards/.github/workflows/scorecard-reusable.yml@892497fe373744874316710966b81ae6f0ea9e66
    timeout-minutes: 10
YAML
          ( cd "$1" && git add -A >/dev/null 2>&1 ); }
m_W4()  { :; }  # the untouched parse fixture is the silence case
m_W5()  { printf 'name: flow\non: [push]\njobs: {build: {runs-on: ubuntu-latest, steps: [{uses: %s}]}}\n' "'actions/checkout@$SHA'" > "$1/.github/workflows/flow.yml"
          ( cd "$1" && git add -A >/dev/null 2>&1 ); }

# ── the catalogue ──────────────────────────────────────────────────────────
# id | gate | fixture-builder | expected rc | mutator | env | must also print
# Expected codes are the gate's own documented contract, and a mutant is killed
# only by returning that exact code.
CATALOGUE=(
  # check-lock-sync.sh — members of declared drift classes, must be killed with 1
  "S1|sync|new_sync_fixture|1|m_S1||refs missing from the lockfile: actions/setup-node@$OTHER"
  "S2|sync|new_sync_fixture|1|m_S2||stale lockfile entries: actions/setup-node@$OTHER"
  "S3|sync|new_sync_fixture|1|m_S3||stale lockfile entry: no such workflow file"
  "S4|sync|new_sync_fixture|1|m_S4||no dependencies record"
  "S5|sync|new_sync_fixture|1|m_S5||the recorded commit disagrees"
  "S6|sync|new_sync_fixture|1|m_S6||schema requires commit: sha1-"
  "S7|sync|new_sync_fixture|1|m_S7||no resolvable commit"
  "S8|sync|new_sync_fixture|1|m_S8||malformed dependency key"
  "S9|sync|new_sync_fixture|1|m_S9||malformed dependency key"
  "S10|sync|new_sync_fixture|1|m_S10||malformed dependency key"
  "S11|sync|new_sync_fixture|1|m_S11||transitive pin is not recorded as a dependency"
  "S12|sync|new_sync_fixture|1|m_S12||not a path under .github/workflows"
  "S13|sync|new_sync_fixture|1|m_S13||actions/checkout@$TAGREF"
  "S14|sync|new_sync_fixture|1|m_S14||hyperpolymath/standards@892497fe373744874316710966b81ae6f0ea9e66"
  "S2b|sync|new_sync_fixture|1|m_S2b||stale lockfile entries: actions/setup-node@$OTHER"
  "S20|sync|new_sync_fixture|1|m_S20||schema requires commit: sha1-"
  # check-lock-sync.sh — the two ways it can fake a verdict, must answer 2
  "S15|sync|new_sync_fixture|2|m_S15||NO CHECK WAS PERFORMED"
  "S16|sync|new_sync_fixture|2|m_S16||NO CHECK WAS PERFORMED"
  "S17|sync|new_sync_fixture|2|m_S17||NO CHECK WAS PERFORMED"
  "S18|sync|new_sync_fixture|2|m_S18||NO CHECK WAS PERFORMED"
  "S19|sync|new_sync_fixture|2||YAML_PARSER_KIND=none|NO CHECK WAS PERFORMED"
  # check-lock-sync.sh — benign variants, must be spared (exit 0)
  "B1|sync|new_sync_fixture|0|m_B1||"
  "B2|sync|new_sync_fixture|0|m_B2||every workflow agrees"
  "B3|sync|new_sync_fixture|0|m_B3||"
  "B4|sync|new_sync_fixture|0|m_B4||"
  "B5|sync|new_sync_fixture|0|m_B5||not onboarded: .github/workflows/gamma.yml"
  "B6|sync|new_sync_fixture|0|m_B6||not onboarded: .github/workflows/gamma.yml"
  "B7|sync|new_sync_fixture|0|m_B7||not in the enforcement cohort"
  "B8|sync|new_sync_fixture|0|m_B8||"
  "B9|sync|new_sync_fixture|0|m_B9||every workflow agrees"
  "B10|sync|new_sync_fixture|0|m_B10||every workflow agrees"
  "B11|sync|new_sync_fixture|0|m_B11||every workflow agrees"
  # check-lock-pins.sh — the determinate/indeterminate split, driven by the stub
  "P1|pins|new_pins_fixture|0||STUB_CODE=200|resolved 2, dead 0, unverified 0"
  "P2|pins|new_pins_fixture|1||STUB_CODE=404|DEAD actions/setup-node"
  "P3|pins|new_pins_fixture|1||STUB_CODE=422|DEAD actions/setup-node"
  "P4|pins|new_pins_fixture|1|m_P4|STUB_CODE=200|no resolvable commit recorded"
  "P5|pins|new_pins_fixture|0||STUB_CODE=403|UNVERIFIED actions/setup-node"
  "P6|pins|new_pins_fixture|0||STUB_CODE=503|UNVERIFIED actions/setup-node"
  "P7|pins|new_pins_fixture|0||STUB_CODE=NETFAIL|UNVERIFIED actions/setup-node"
  "P8|pins|new_pins_fixture|2||PATH_WITHOUT_GH=1|NO CHECK WAS PERFORMED"
  "P9|pins|new_pins_fixture|2||YAML_PARSER_KIND=none|NO CHECK WAS PERFORMED"
  "P10|pins|new_pins_fixture|0||STUB_CODE=404 SKIP_PIN_RESOLUTION=1|resolution skipped"
  # check-workflows-parse.sh — scored only where yq or ruby exists
  "W1|parse|new_parse_fixture|1|m_W1||does not parse"
  "W2|parse|new_parse_fixture|1|m_W2||no executable jobs"
  "W3|parse|new_parse_fixture|1|m_W3||cannot declare timeout-minutes"
  "W4|parse|new_parse_fixture|0|m_W4||parse"
  "W5|parse|new_parse_fixture|0|m_W5||parse"
)

build_nogh_path() { # populate $TMP/nogh with every tool the gate may need except gh
  [ -d "$TMP/nogh" ] && return 0
  mkdir -p "$TMP/nogh"
  local t
  for t in jq grep sed sort head cut comm uniq awk bash cat printf mktemp wc tr od \
           python3 python ruby yq dirname basename env git sha256sum date uname ls rm mv cp ln; do
    [ -n "$(command -v "$t" 2>/dev/null)" ] && ln -sf "$(command -v "$t")" "$TMP/nogh/$t"
  done
}

run_gate() { # run_gate <gate> <dir> <env-string>
  local gate="$1" d="$2" envs="$3"
  case "$gate" in
    sync)  env $envs bash "$SYNC_GATE" "$d" > "$OUT" 2> "$ERR" ;;
    pins)
      if [ "$envs" != "${envs/PATH_WITHOUT_GH=1/}" ]; then
        # A PATH holding everything the gate needs EXCEPT gh, so the case tests
        # the gh requirement and not the parser requirement. The parsers have to
        # be in there: omitting them would make the gate answer 2 for the wrong
        # reason and the mutant would score as killed when nothing was proved.
        build_nogh_path
        env $envs PATH="$TMP/nogh" bash "$PINS_GATE" "$d" > "$OUT" 2> "$ERR"
      else
        env PATH="$STUBBIN:$PATH" $envs bash "$PINS_GATE" "$d" > "$OUT" 2> "$ERR"
      fi
      ;;
    parse) ( cd "$d" && env $envs bash "$PARSE_GATE" ) > "$OUT" 2> "$ERR" ;;
  esac
}

declare -A BASE_RC=()
killed=0; should_kill=0; spared=0; should_spare=0; wrongcode=0; falsealarm=0; missed=0; skipped=0

echo
echo "== PART A: input mutation — the fixtures are the mutants =="
printf '  %-5s %-6s %-8s %-6s %s\n' ID GATE EXPECT GOT VERDICT
for entry in "${CATALOGUE[@]}"; do
  IFS='|' read -r id gate builder expect mutator envs mustprint <<< "$entry"
  if [ "$gate" = "parse" ] && [ -z "$PARSE_INSTRUMENT" ]; then
    skipped=$((skipped + 1))
    [ "$VERBOSE" = "1" ] && printf '  %-5s %-6s %-8s %-6s %s\n' "$id" "$gate" "$expect" "-" "NOT SCORED (no yq/ruby)"
    continue
  fi
  d="$("$builder" "$id")"
  [ -n "$mutator" ] && "$mutator" "$d"
  run_gate "$gate" "$d" "$envs"
  rc=$?
  BASE_RC["$id"]=$rc
  out_all="$(cat "$OUT" "$ERR")"

  verdict=""
  if [ "$expect" = "0" ]; then
    should_spare=$((should_spare + 1))
    if [ "$rc" -eq 0 ]; then
      spared=$((spared + 1)); verdict="SPARED (correct)"
    else
      falsealarm=$((falsealarm + 1)); verdict="FALSE ALARM"
      bad "$id ($gate): a benign variant was called drift — rc=$rc, want 0"
      printf '%s\n' "$out_all" | sed 's/^/      | /'
    fi
  else
    should_kill=$((should_kill + 1))
    if [ "$rc" -eq "$expect" ]; then
      killed=$((killed + 1)); verdict="KILLED (rc=$rc)"
    elif [ "$rc" -eq 0 ]; then
      missed=$((missed + 1)); verdict="SURVIVED"
      bad "$id ($gate): the mutant SURVIVED — rc=0, want $expect"
      printf '%s\n' "$out_all" | sed 's/^/      | /'
    else
      wrongcode=$((wrongcode + 1)); verdict="WRONG-CODE rc=$rc"
      bad "$id ($gate): killed with the wrong exit code — rc=$rc, want $expect (an instrument failure is not a detection)"
      printf '%s\n' "$out_all" | sed 's/^/      | /'
    fi
  fi

  if [ -n "$mustprint" ] && [ "$verdict" != "FALSE ALARM" ]; then
    if printf '%s' "$out_all" | grep -qF "$mustprint"; then
      :
    else
      bad "$id ($gate): right exit code but the finding was not named — wanted '$mustprint'"
      printf '%s\n' "$out_all" | sed 's/^/      | /'
      verdict="$verdict +UNNAMED"
    fi
  fi
  [ "$VERBOSE" = "1" ] && printf '  %-5s %-6s %-8s %-6s %s\n' "$id" "$gate" "$expect" "$rc" "$verdict"
done

detection="n/a"; specificity="n/a"
[ "$should_kill" -gt 0 ] && detection="$(awk -v k="$killed" -v t="$should_kill" 'BEGIN { printf "%.1f", (k / t) * 100 }')"
[ "$should_spare" -gt 0 ] && specificity="$(awk -v s="$spared" -v t="$should_spare" 'BEGIN { printf "%.1f", (s / t) * 100 }')"

echo
echo "  input mutants:  $should_kill should be killed, $killed were (detection ${detection}%)"
echo "                  $should_spare should be spared, $spared were (specificity ${specificity}%)"
echo "                  missed=$missed wrong-code=$wrongcode false-alarm=$falsealarm not-scored=$skipped"

# ── PART B: code mutation — the gates are the mutants ──────────────────────
# Each mutation deletes or inverts one documented decision. A mutant is killed
# only if some corpus member's verdict CHANGES, which is the textbook criterion
# and the reason the benign inputs above are part of the corpus.
awk_mutate() { # awk_mutate <in> <out> <fixed needle> <replacement line>
  awk -v needle="$3" -v repl="$4" '
    index($0, needle) { print repl; found = 1; next }
    { print }
    END { if (!found) exit 3 }
  ' "$1" > "$2"
}

build_code_mutant() { # build_code_mutant <name> <gate-script> <needle> <replacement> -> path or rc 2
  # Two statements, not one: `local` expands every word before it assigns any
  # of them, so dir="$TMP/code-$name" on the same line reads a variable that
  # does not exist yet — and under set -u that is a hard error, while without
  # it the mutant directory is silently named after whatever the caller had.
  local name="$1" src="$2" needle="$3" repl="$4"
  local dir="$TMP/code-$name"
  rm -rf "$dir"; mkdir -p "$dir/scripts"
  ln -s "$ROOT/scripts/lib" "$dir/scripts/lib"
  if ! awk_mutate "$src" "$dir/scripts/$(basename "$src")" "$needle" "$repl"; then
    return 2
  fi
  printf '%s' "$dir/scripts/$(basename "$src")"
}

CODE_MUTANTS=(
  "C1|$SYNC_GATE|missing=\"\$(comm -23|  missing=\"\"|sync|S1: a ref the lock does not record stops being drift"
  "C2|$SYNC_GATE|stale=\"\$(comm -13|  stale=\"\"|sync|S2: a lock entry the workflow no longer requests stops being drift"
  "C3|$SYNC_GATE|sha1-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) : ;;|    *) : ;;|sync|Check 3: any commit value is accepted, malformed or absent"
  "C4|$SYNC_GATE|if [ \"\$commit\" != \"sha1-\$ref\" ]; then|    if false; then|sync|Check 3: a SHA ref whose recorded commit disagrees is accepted"
  "C5|$SYNC_GATE|unlisted+=(\"\$key\")|    fail_block \"\$key\"|sync|Calibration: the coverage NOTE becomes a FAIL — the false alarm the gate header warns against"
  "C6|$PINS_GATE|RESOLVE_VERDICT=\"dead\"|      RESOLVE_VERDICT=\"unverified\"|pins|A determinate 404/422 stops being DEAD — a dead pin sails through as merely unverified"
)

echo
echo "== PART B: code mutation — the gates are the mutants =="
DEBUG="${MUTATION_DEBUG:-0}"
code_run=0; code_killed=0; code_unbuilt=0; nobaseline=0
for entry in "${CODE_MUTANTS[@]}"; do
  IFS='|' read -r id src needle repl gate why <<< "$entry"
  if ! mutated="$(build_code_mutant "$id" "$src" "$needle" "$repl")"; then
    code_unbuilt=$((code_unbuilt + 1))
    bad "$id: the anchor line is no longer in $(basename "$src") — NO CHECK WAS PERFORMED for this mutant"
    echo "      anchor: $needle"
    continue
  fi
  code_run=$((code_run + 1))
  killing_input=""; differing=0
  for probe in "${CATALOGUE[@]}"; do
    IFS='|' read -r pid pgate builder expect mutator envs mustprint <<< "$probe"
    [ "$pgate" = "$gate" ] || continue
    d="$("$builder" "cb-$id-$pid")"
    [ -n "$mutator" ] && "$mutator" "$d"
    case "$gate" in
      sync)  env $envs bash "$mutated" "$d" > "$OUT" 2> "$ERR" ;;
      pins)
        if [ "$envs" != "${envs/PATH_WITHOUT_GH=1/}" ]; then
          build_nogh_path
          env $envs PATH="$TMP/nogh" bash "$mutated" "$d" > "$OUT" 2> "$ERR"
        else
          env PATH="$STUBBIN:$PATH" $envs bash "$mutated" "$d" > "$OUT" 2> "$ERR"
        fi
        ;;
    esac
    rc=$?
    if [ "${BASE_RC[$pid]+set}" != "set" ]; then
      # No baseline for this corpus member means Part A did not score it (e.g.
      # the parse family with no yq/ruby). Comparing against nothing would
      # manufacture a kill, so it is skipped and counted.
      nobaseline=$((nobaseline + 1))
      continue
    fi
    [ "$DEBUG" = "1" ] && printf '      [debug] %s/%s: baseline rc=%s mutant rc=%s\n' "$id" "$pid" "${BASE_RC[$pid]}" "$rc"
    if [ "$rc" != "${BASE_RC[$pid]}" ]; then
      differing=$((differing + 1))
      [ -z "$killing_input" ] && killing_input="$pid (rc ${BASE_RC[$pid]} -> $rc)"
      if [ "$DEBUG" = "1" ]; then
        printf '      [debug] first differing output:\n'
        sed 's/^/        | /' "$OUT" | head -12
        sed 's/^/        E /' "$ERR" | head -6
      fi
    fi
  done
  if [ "$differing" -gt 0 ]; then
    code_killed=$((code_killed + 1))
    ok "$id killed by $differing corpus input(s), first: $killing_input"
    echo "      mutation: $why"
  else
    bad "$id SURVIVED the whole corpus — nobody would notice: $why"
  fi
done

code_score="n/a"
[ "$code_run" -gt 0 ] && code_score="$(awk -v k="$code_killed" -v t="$code_run" 'BEGIN { printf "%.1f", (k / t) * 100 }')"
echo
echo "  code mutants:   $code_run constructed, $code_killed killed by the corpus (mutation score ${code_score}%), $code_unbuilt not constructible, $nobaseline corpus member(s) without a Part A baseline"

# ── verdict ────────────────────────────────────────────────────────────────
echo
if [ "$code_unbuilt" -ne 0 ]; then
  echo "mutation-score-test: $code_unbuilt code mutant(s) could not be constructed — NO CHECK WAS PERFORMED for them" >&2
  exit 2
fi
if [ "$fail" -ne 0 ] || [ "$killed" -ne "$should_kill" ] || [ "$spared" -ne "$should_spare" ] || [ "$code_killed" -ne "$code_run" ]; then
  echo "mutation-score-test: detection ${detection}% (${killed}/${should_kill}), specificity ${specificity}% (${spared}/${should_spare}), code mutation score ${code_score}% (${code_killed}/${code_run}) — below the declared threshold of 100/100/100" >&2
  exit 1
fi
echo "mutation-score-test: detection ${detection}% (${killed}/${should_kill}), specificity ${specificity}% (${spared}/${should_spare}), code mutation score ${code_score}% (${code_killed}/${code_run})"
if [ "$skipped" -gt 0 ]; then
  echo "mutation-score-test: $skipped parse-gate mutant(s) NOT SCORED in this environment (no yq/ruby) — excluded, not passed"
fi
echo "mutation-score-test: every declared mutant behaved as declared"
exit 0
