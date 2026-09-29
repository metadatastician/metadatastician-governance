#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/checkers"
cat >"$T/bin/gh" <<'SH'
#!/usr/bin/env bash
set -e
if [ "$1" = actions-lock ]; then
  printf 'new-lock\n' > .github/workflows/actions.lock
  case "${FIXTURE:-}" in
    # standards#981 shapes, both measured against the real generator: one only
    # churns a comment (the original YAML still verifies against the new
    # lock), one re-keys the ref (the original YAML can never verify: the lock
    # entry names the tag the generator wrote, not the SHA the file carries).
    banner) printf '# regenerated banner\n' >>.github/workflows/ci.yml ;;
    depin) sed -i 's/name: CI/name: CI tag-keyed/' .github/workflows/ci.yml ;;
  esac
  exit 0
fi
shift
case "$*" in
  'repos/metadatastician/sample --jq [.'*) printf 'false\tfalse\tmain\n';;
  *'/git/trees/main?recursive=1'*)
    # Run the caller's --jq filter against a tree that holds NON-workflow entries too,
    # as gh does. A stub that returned already-filtered text could not see a broken
    # filter -- which is how a jq precedence bug shipped (`.path | test(..) or
    # .path==..` evaluates the right-hand `.path` on a string) that made lockfix.sh
    # fail with "tree API failed" for every repository that has any other file.
    expr=''; prev=''
    for a in "$@"; do [ "$prev" = --jq ] && expr="$a"; prev="$a"; done
    printf '%s' '{"tree":[{"path":"README.md","type":"blob"},{"path":".github","type":"tree"},{"path":".github/workflows","type":"tree"},{"path":".github/workflows/ci.yml","type":"blob"},{"path":".github/workflows/actions.lock","type":"blob"},{"path":"src/main.rs","type":"blob"}]}' | jq -r "$expr";;
  *'/contents/.github/workflows/ci.yml?ref=main'*) printf 'bmFtZTogQ0kK';;
  *'/contents/.github/workflows/actions.lock?ref=main'*) printf 'b2xkLWxvY2sK';;
  *'/git/ref/heads/main'*) printf 'abc123\n';;
  *'/branches/ci/ci-health-lockfix'*) exit 1;;
  *'/git/refs -f ref='*) echo '{}' ;;
  *'/contents/.github/workflows/actions.lock?ref=ci/ci-health-lockfix'*) printf '{"sha":"oldsha","content":"b2xkLWxvY2sK"}\n';;
  *'/contents/.github/workflows/actions.lock -f message='*) echo '{}' ;;
  *'/pulls -X POST'*) echo 'https://example.test/pr/1';;
  *) echo "unexpected gh: $*" >&2; exit 1;;
esac
SH
# The fake checker models the exit contract; production uses parser-first gates.
# The banner/depin fixtures make the checker state-aware, because that is the
# only way to prove WHICH YAML the checker was run against: if the restore did
# not happen, the mirror still carries the generator's rewrite and the verdict
# must flip.
cat >"$T/checkers/check-lock-sync.sh" <<'SH'
#!/usr/bin/env bash
case "${FIXTURE:-}" in
  instrument) exit 2 ;;
  clean) exit 0 ;;
  banner)
    if [ "$(cat "$1/.github/workflows/ci.yml")" = 'name: CI' ] && grep -q new-lock "$1/.github/workflows/actions.lock"; then exit 0; fi
    echo 'FAIL .github/workflows/ci.yml the generator rewrite is present (original YAML was not restored)'
    exit 1 ;;
  depin)
    # The new lock keys the TAG; only the generator's rewritten (tag-keyed)
    # YAML can agree with it. The original SHA-pinned YAML drifts by design.
    if grep -q 'name: CI tag-keyed' "$1/.github/workflows/ci.yml" && grep -q new-lock "$1/.github/workflows/actions.lock"; then exit 0; fi
    echo 'FAIL .github/workflows/ci.yml refs missing from the lockfile: actions/checkout@<original SHA> (lock keys the generator-written tag)'
    exit 1 ;;
esac
if grep -q new-lock "$1/.github/workflows/actions.lock"; then exit 0; fi
echo 'FAIL .github/workflows/ci.yml refs missing from the lockfile: actions/checkout@v4'
exit 1
SH
cat >"$T/checkers/check-lock-pins.sh" <<'SH'
#!/usr/bin/env bash
# Records every invocation so the test can assert the offline mode flag; a pin
# gate that resolves over the network during a repair is a teardown risk.
printf '%s\n' "$*" >>"${PIN_CALLS:?}"
# Only the POST-regeneration mirror is judged: pre-generation this fixture is
# ordinary drift (the pre-gen pin check would otherwise misreport it B-BADPIN).
if [ "${FIXTURE:-}" = depin ] && grep -q new-lock "$1/.github/workflows/actions.lock"; then
  echo 'DEAD actions/checkout@v4 -> tag record, not a full-length commit (offline verdict)'
  exit 1
fi
exit 0
SH
chmod +x "$T/bin/gh" "$T/checkers/"*.sh
export PATH="$T/bin:$PATH" LOCKFIX_CHECKERS_DIR="$T/checkers" GH_TOKEN=fixture PIN_CALLS="$T/pin-calls"
run() { set +e; output=$(FIXTURE="$1" "$ROOT/scripts/ci-health/lockfix.sh" sample "$2" 'ci.yml checkout@v4; failed run 123' 2>&1); rc=$?; set -e; }
run clean false
[ "$rc" = 2 ] && [[ "$output" == *'require ENABLE_LOCKFIX_PRS'* ]] || { echo "FAIL live default: $rc $output"; exit 1; }
echo 'ok default live refusal'
export ENABLE_LOCKFIX_PRS=true
run clean false
[ "$rc" = 0 ] && [[ "$output" == *'SKIP sample/B-LOCKFIX clean; no PR'* ]] || { echo "FAIL silence: $rc $output"; exit 1; }
echo 'ok silence fixture: zero PRs'
run drift false
[ "$rc" = 0 ] && [ "$(grep -c '^FIXED ' <<<"$output")" = 1 ] || { echo "FAIL firing: $rc $output"; exit 1; }
echo 'ok firing fixture: exactly one PR'
run instrument true
[ "$rc" = 2 ] && [[ "$output" == *'E-INSTRUMENT'* ]] || { echo "FAIL exit-2: $rc $output"; exit 1; }
echo 'ok checker exit-2 cannot pass'
unset GH_TOKEN
run drift true
[ "$rc" = 2 ] && [[ "$output" == *'GH_TOKEN missing'* ]] || { echo "FAIL no token: $rc $output"; exit 1; }
echo 'ok absent token exit-2'
export GH_TOKEN=fixture

# ── standards#981: the generator rewrote workflow YAML ──────────────────────
# Two shapes measured against the real generator: a banner-only touch (the
# original YAML still verifies against the new lock, so a lock-only repair
# exists) and a de-pinning touch (the lock keys the tag the generator wrote;
# the original YAML can never verify, so the honest answer is a human report).
run banner true
[ "$rc" = 0 ] && [[ "$output" == *'PROPOSED sample/B-LOCKFIX lock-only diff (workflow YAML restored unchanged)'* ]] || { echo "FAIL banner recovered: $rc $output"; exit 1; }
[[ "$output" != *'REPORT sample/B-LOCKFIX standards#981: generator requires workflow YAML rewrite; NO PR'* ]] || { echo 'FAIL banner touch misreported as rewrite-required'; exit 1; }
echo 'ok banner-only touch: original YAML restored, lock-only repair PROPOSED'
grep -q -- '--offline' "$PIN_CALLS" || { echo "FAIL pin gate did not run with --offline on the restored mirror: $(cat "$PIN_CALLS")"; exit 1; }
echo 'ok pin gate ran in --offline mode on the restored mirror'
run banner false
[ "$rc" = 0 ] && [[ "$output" == *'FIXED sample/B-LOCKFIX'* ]] || { echo "FAIL banner live: $rc $output"; exit 1; }
echo 'ok banner-only touch: live repair opens the lock-only PR'
run depin true
[ "$rc" = 0 ] && [[ "$output" == *'REPORT sample/B-LOCKFIX standards#981: generator requires workflow YAML rewrite; NO PR'* ]] || { echo "FAIL depin reported: $rc $output"; exit 1; }
[[ "$output" != *'PROPOSED'* ]] || { echo 'FAIL depin proposed a lock-only diff it cannot support'; exit 1; }
echo 'ok de-pinned ref: REPORT with NO PR, never a false PROPOSED'
run depin false
[ "$rc" = 0 ] && [[ "$output" == *'REPORT sample/B-LOCKFIX standards#981: generator requires workflow YAML rewrite; NO PR'* ]] && [[ "$output" != *'FIXED'* ]] || { echo "FAIL depin live opened a PR: $rc $output"; exit 1; }
echo 'ok de-pinned ref: live mode still opens nothing'

# ── Mutants for the restore-then-verify rule ────────────────────────────────
# M1 restores nothing: the banner-only touch then looks like a real rewrite.
MUT="$T/lockfix-norestore.sh"
sed 's|for f in "$tmp/before"/\*\.yml "$tmp/before"/\*\.yaml; do|for f in /nonexistent-mutant-never-exists; do|' \
  "$ROOT/scripts/ci-health/lockfix.sh" >"$MUT"
if cmp -s "$MUT" "$ROOT/scripts/ci-health/lockfix.sh"; then echo 'FAIL mutant skip-restore: expression did not change the script (stale test)'; exit 1; fi
set +e; output=$(FIXTURE=banner bash "$MUT" sample true 'ci.yml checkout@v4; failed run 123' 2>&1); rc=$?; set -e
if [[ "$output" == *'PROPOSED'* ]]; then echo "FAIL mutant skip-restore SURVIVED: $rc $output"; exit 1; fi
echo 'ok mutant skip-restore killed (without the restore a banner touch can no longer be PROPOSED)'
# M2 ignores the restored-verify verdict: a de-pin would be PROPOSED anyway.
MUT="$T/lockfix-ignore-verdict.sh"
sed 's~if \[ "$verified_rc" -ne 0 \] || \[ "$pin_rc" -ne 0 \]; then~if false; then~' \
  "$ROOT/scripts/ci-health/lockfix.sh" >"$MUT"
if cmp -s "$MUT" "$ROOT/scripts/ci-health/lockfix.sh"; then echo 'FAIL mutant ignore-verdict: expression did not change the script (stale test)'; exit 1; fi
set +e; output=$(FIXTURE=depin bash "$MUT" sample true 'ci.yml checkout@v4; failed run 123' 2>&1); rc=$?; set -e
if [[ "$output" == *'REPORT sample/B-LOCKFIX standards#981: generator requires workflow YAML rewrite; NO PR'* ]]; then echo "FAIL mutant ignore-verdict SURVIVED: $rc $output"; exit 1; fi
echo 'ok mutant ignore-verdict killed (the de-pin can no longer pass silently)'
