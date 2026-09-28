#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
#
# Regression cover for scripts/check-lock-pins.sh.
#
# The property under test is the DISTINCTION the checker draws, not the fact
# that it can find a bad pin:
#
#   404/422 from the commits endpoint -> determinate; the pin is dead; FAIL
#   403/429/5xx/network loss           -> indeterminate; says NOTHING about the
#                                         pin; report LOUDLY, do NOT fail
#
# Get that backwards in either direction and the tool is worse than absent:
# fail-closed on a rate limit reddens the estate for reasons unrelated to its
# code, and fail-open silently lets a genuinely dead pin sail through.
#
# The network is driven by a `gh` stub placed ahead of the real binary on PATH,
# so every branch is reachable offline and repeatably.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-lock-pins.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

if [ "$(bash -c ". '$ROOT/scripts/lib/yaml.sh'; yaml_parser_kind")" = "none" ]; then
  echo "SKIP: no YAML parser available in this environment"
  exit 0
fi

# ── the gh stub ────────────────────────────────────────────────────────────
# STUB_CODE selects the answer: 200 prints a sha, anything else prints gh's
# REST error shape on stderr and exits non-zero, exactly as the real CLI does.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
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
chmod +x "$TMP/bin/gh"

# ── fixtures ───────────────────────────────────────────────────────────────
SHA=3d3c42e5aac5ba805825da76410c181273ba90b1

new_root() { # new_root <name> <commit-field-for-second-dep>
  local d="$TMP/$1" commit="$2"
  mkdir -p "$d/.github/workflows"
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
        commit: '$commit'
        owner_id: 44036562
        repo_id: 194000000
YAML
  printf '%s' "$d"
}

run_check() { # run_check <dir> [env...]
  local d="$1"; shift
  env PATH="$TMP/bin:$PATH" "$@" bash "$CHECK" "$d" > "$TMP/out" 2> "$TMP/err"
  return $?
}

# ── Silence fixture: every pin resolves ────────────────────────────────────
d="$(new_root ok "sha1-1111111111111111111111111111111111111111")"
run_check "$d" STUB_CODE=200; rc=$?
if [ "$rc" -eq 0 ]; then ok "all pins resolve: exit 0"; else bad "all pins resolve: rc=$rc"; cat "$TMP/out" "$TMP/err"; fi
if grep -q 'resolved 2, dead 0, unverified 0' "$TMP/out"; then ok "all pins resolve: stated population"; else bad "all pins resolve: no population line"; cat "$TMP/out"; fi

# ── Firing fixture: determinate negative → DEAD, exit 1 ────────────────────
d="$(new_root dead "sha1-1111111111111111111111111111111111111111")"
run_check "$d" STUB_CODE=404; rc=$?
if [ "$rc" -eq 1 ]; then ok "404: exit 1"; else bad "404: rc=$rc (want 1)"; cat "$TMP/out"; fi
if grep -q 'DEAD actions/setup-node@1111' "$TMP/out"; then ok "404: names the dead pin"; else bad "404: did not name the pin"; cat "$TMP/out"; fi

# ── Firing fixture: indeterminate answer → NOT a failure, but LOUD ─────────
# This is the payload of the whole script. Rerun the same fixture with each
# indeterminate answer; none may fail, and each must be reported.
for code in 403 503 NETFAIL; do
  d="$(new_root indet_$code "sha1-1111111111111111111111111111111111111111")"
  run_check "$d" STUB_CODE="$code"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$code: exit 0 (indeterminate answers say nothing about the pin)"
  else
    bad "$code: rc=$rc (must not fail on an indeterminate answer)"
  fi
  if grep -q 'UNVERIFIED actions/setup-node@1111' "$TMP/out" && grep -q 'unverified 2' "$TMP/out"; then
    ok "$code: reported as UNVERIFIED, not hidden"
  else
    bad "$code: unverified pin was not announced"; cat "$TMP/out"
  fi
  if grep -q 'PASS on the 0 pin(s)' "$TMP/err"; then
    ok "$code: says the pass is partial, not total"
  else
    bad "$code: pass was not qualified"; cat "$TMP/err"
  fi
  if grep -q 'every recorded pin resolves' "$TMP/out"; then
    bad "$code: claimed every pin resolves while pins went unexamined"
  else
    ok "$code: does not claim a clean sweep it did not make"
  fi
done

# ── Firing fixture: malformed commit record (no API call needed) ───────────
d="$(new_root malformed "not-a-sha1")"
run_check "$d" STUB_CODE=200; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'no resolvable commit recorded' "$TMP/out"; then
  ok "malformed commit record: exit 1 and named"
else
  bad "malformed commit record: rc=$rc"; cat "$TMP/out"
fi

# ── Firing fixture: instrument failures must be exit 2, never a pass ───────
d="$(new_root no_gh "sha1-1111111111111111111111111111111111111111")"
# A PATH with the YAML tools but deliberately without `gh`, so the case tests
# the gh requirement and not the parser requirement.
mkdir -p "$TMP/nogh"
for t in yq jq grep sed sort head cut comm; do
  [ -n "$(command -v "$t" 2>/dev/null)" ] && ln -sf "$(command -v "$t")" "$TMP/nogh/$t"
done
env PATH="$TMP/nogh" "$(command -v bash)" "$CHECK" "$d" > "$TMP/out" 2> "$TMP/err"
rc=$?
if [ "$rc" -eq 2 ]; then ok "no gh: exit 2 (NO CHECK)"; else bad "no gh: rc=$rc (want 2)"; cat "$TMP/out" "$TMP/err"; fi

env YAML_PARSER_KIND=none bash "$CHECK" "$d" > "$TMP/out" 2> "$TMP/err"
rc=$?
if [ "$rc" -eq 2 ]; then ok "no parser: exit 2 (NO CHECK)"; else bad "no parser: rc=$rc (want 2)"; fi

# ── Silence fixture: parse-only mode still fails closed without a parser ───
d="$(new_root parse_only "sha1-1111111111111111111111111111111111111111")"
run_check "$d" STUB_CODE=404 SKIP_PIN_RESOLUTION=1; rc=$?
if [ "$rc" -eq 0 ] && grep -q 'resolution skipped' "$TMP/out"; then
  ok "parse-only run: exit 0, API not consulted"
else
  bad "parse-only run: rc=$rc"; cat "$TMP/out"
fi
env YAML_PARSER_KIND=none SKIP_PIN_RESOLUTION=1 bash "$CHECK" "$d" >/dev/null 2>&1
if [ $? -eq 2 ]; then ok "parse-only run with no parser: still exit 2"; else bad "parse-only run with no parser did not fail closed"; fi

# ── Silence fixture: no lockfile is not a failure ──────────────────────────
d="$TMP/nolock"; mkdir -p "$d"
run_check "$d" STUB_CODE=200; rc=$?
if [ "$rc" -eq 0 ]; then ok "no lockfile: exit 0"; else bad "no lockfile: rc=$rc"; fi

echo
if [ "$fail" -ne 0 ]; then
  echo "lock-pins-test: $fail failure(s), $pass pass(es)" >&2
  exit 1
fi
echo "lock-pins-test: all $pass check(s) passed"
