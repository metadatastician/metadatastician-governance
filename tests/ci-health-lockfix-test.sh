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
  exit 0
fi
shift
case "$*" in
  'repos/metadatastician/sample --jq [.'*) printf 'false\tfalse\tmain\n';;
  *'/git/trees/main?recursive=1'*) printf '.github/workflows/ci.yml\n.github/workflows/actions.lock\n';;
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
cat >"$T/checkers/check-lock-sync.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FIXTURE:-}" = instrument ]; then exit 2; fi
if [ "${FIXTURE:-}" = clean ]; then exit 0; fi
if grep -q new-lock "$1/.github/workflows/actions.lock"; then exit 0; fi
echo 'FAIL .github/workflows/ci.yml refs missing from the lockfile: actions/checkout@v4'
exit 1
SH
cat >"$T/checkers/check-lock-pins.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$T/bin/gh" "$T/checkers/"*.sh
export PATH="$T/bin:$PATH" LOCKFIX_CHECKERS_DIR="$T/checkers" GH_TOKEN=fixture
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
