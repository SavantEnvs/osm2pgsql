#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# RUN the upstream catch2 tests labelled NoDB (built by mayhem/build.sh in build/tests with upstream's
# normal flags). Each binary's own Catch2 summary line is parsed, so a test binary that exits 0 without
# running its assertions counts as failed — the oracle checks asserted results, not exit codes.
TDIR="$SRC/build/tests/tests"
NODB_TESTS=$(sed -n 's/^ *set_test(\(test-[a-z0-9-]*\) LABELS NoDB).*/\1/p' "$SRC/tests/CMakeLists.txt")
[ -n "$NODB_TESTS" ] || { echo "no NoDB tests found" >&2; emit_ctrf catch2 0 1; exit 1; }

passed=0 failed=0
for t in $NODB_TESTS; do
  bin="$TDIR/$t"
  if [ ! -x "$bin" ]; then
    echo "FAIL $t: binary missing (mayhem/build.sh should have built it)" >&2
    failed=$((failed + 1)); continue
  fi
  out=$(cd "$TDIR" && "$bin" 2>&1); rc=$?
  if [ $rc -eq 0 ] && line=$(printf '%s\n' "$out" | grep -E '^All tests passed \([0-9]+ assertions? in [0-9]+ test cases?\)'); then
    n=$(printf '%s\n' "$line" | sed -E 's/.* in ([0-9]+) test case.*/\1/')
    passed=$((passed + n))
    echo "PASS $t ($n test cases)"
  else
    line=$(printf '%s\n' "$out" | grep -E '^test cases: ' | tail -1)
    p=$(printf '%s\n' "$line" | sed -nE 's/.*\| *([0-9]+) passed.*/\1/p'); p=${p:-0}
    f=$(printf '%s\n' "$line" | sed -nE 's/.*\| *([0-9]+) failed.*/\1/p'); f=${f:-1}
    passed=$((passed + p)); failed=$((failed + f))
    printf '%s\n' "$out" | tail -30 >&2
    echo "FAIL $t (rc=$rc, $line)" >&2
  fi
done

emit_ctrf catch2 "$passed" "$failed" 0
