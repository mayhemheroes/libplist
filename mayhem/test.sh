#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libplist's entire upstream test suite (automake `make check`,
# 42 .test scripts: round-trip/compare oracles via plist_cmp/plist_test over the
# XML/binary/JSON/OpenStep formats). build.sh already compiled build-tests/ with
# normal flags; this only runs the suite and reports CTRF counts.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

[ -d build-tests/test ] || { echo "test.sh: build-tests/ missing — build.sh must run first" >&2; emit_ctrf automake-check 0 1; exit 1; }

log=$(mktemp)
make -C build-tests/test check 2>&1 | tee "$log"
total=$(sed -n 's/^# TOTAL: *//p' "$log" | tail -1)
pass=$(sed -n 's/^# PASS: *//p' "$log" | tail -1)
skip=$(sed -n 's/^# SKIP: *//p' "$log" | tail -1)
xfail=$(sed -n 's/^# XFAIL: *//p' "$log" | tail -1)
fail=$(sed -n 's/^# FAIL: *//p' "$log" | tail -1)
xpass=$(sed -n 's/^# XPASS: *//p' "$log" | tail -1)
error=$(sed -n 's/^# ERROR: *//p' "$log" | tail -1)
rm -f "$log"

[ -n "${total:-}" ] || { echo "test.sh: could not parse automake test summary" >&2; emit_ctrf automake-check 0 1; exit 1; }

# XFAIL counts as pass (expected), XPASS+ERROR count as failures.
emit_ctrf automake-check "$(( pass + xfail ))" "$(( fail + xpass + error ))" "${skip:-0}"
