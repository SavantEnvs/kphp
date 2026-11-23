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

# Known-answer tests for KPHP's TL schema tools, run on the normal-flag build from mayhem/build.sh:
#   * tl-compiler compiles committed .tl schemas to .tlo; the bytes (minus the timestamp) must match the recorded sha256.
#   * tlo_dump (parse_tlo + the compiler's passes + tl_scheme::to_str) must print the golden text.
#   * tl-compiler must reject a schema with a duplicate constructor, with upstream's message.
#   * ffi_parse (the compiler's FFI C parser) must report the known declarations / enum values / errors.
#   * prepare_search_query (common/unicode clean_str, the PHP builtin of that name) must give the known output.
T="$SRC/mayhem/build/test"
S="$SRC/mayhem/tl-compiler/testsuite"
G="$SRC/mayhem/oracle"
for b in "$T/tl-compiler" "$T/tlo_dump" "$T/prepare_search_query" "$T/ffi_parse"; do
  [ -x "$b" ] || { echo "missing $b — run mayhem/build.sh first" >&2; emit_ctrf "kphp-tl-golden" 0 1 0; exit 1; }
done
W="$(mktemp -d "${TMPDIR:-/tmp}/kphp-test.XXXXXX")"
trap 'rm -rf "$W"' EXIT
passed=0; failed=0
check() { # check <name> <command...>; the command must exit 0
  local name="$1"; shift
  if "$@"; then echo "PASS $name"; passed=$((passed+1)); else echo "FAIL $name"; failed=$((failed+1)); fi
}
tlc_golden() { # tlc_golden <schema> <expected sha256> <golden dump>
  "$T/tl-compiler" -e "$W/$1.tlo" "$S/$1.tl" || return 1
  # bytes 8..11 of a .tlo hold the compile timestamp (tl-parser-new.cpp write_types), so they are masked
  [ "$( { head -c 8 "$W/$1.tlo"; tail -c +13 "$W/$1.tlo"; } | sha256sum | cut -d' ' -f1)" = "$2" ] || return 1
  "$T/tlo_dump" "$W/$1.tlo" > "$W/$1.dump" || return 1
  diff -q "$G/$1.dump" "$W/$1.dump" >/dev/null
}
check "tl-compiler common.tl -> golden .tlo + dump" \
  tlc_golden common a8aa789b0b744adf65da8d2f57cc3dc7697360582872c4bc2b35b2c9080719a1
check "tl-compiler common+tl.tl -> golden .tlo + dump" \
  tlc_golden common+tl ed9064500ec8833e2a32cc91fa35d5584c6a420754bf5187bb7377525cdfb47d
rejects() { # rejects <schema> <expected message>: tl-compiler exits 1 with that message on stderr
  local rc=0
  "$T/tl-compiler" -e "$W/rej.tlo" "$S/$1.tl" 2> "$W/rej.err" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] && grep -qF "$2" "$W/rej.err"
}
check "tl-compiler rejects duplicate constructor" rejects common+crypto_schema 'Duplicate constructor id `boolFalse`'
check "tl-compiler rejects duplicate combinator" rejects common+metric 'Duplicate combinator id pair'
tlo_rejects_text() { # parse_tlo on a non-.tlo file reports a schema error instead of a scheme
  local out rc=0
  out="$("$T/tlo_dump" "$S/common.tl")" || rc=$?
  [ "$rc" -eq 1 ] && [[ "$out" == error:* ]]
}
check "tlo_dump rejects a text file" tlo_rejects_text
psq() { # psq <query> <expected>: prepare_search_query(<query>) prints <expected>
  [ "$("$T/prepare_search_query" "$1")" = "$2" ]
}
check "prepare_search_query folds case, decodes entities, sorts words" \
  psq 'Hello, World! &amp; Привет МИР Café' 'café+hello+world+мир+привет+'
check "prepare_search_query ascii words" psq 'The QUICK brown fox' 'brown+fox+quick+the+'
check "prepare_search_query numeric entities + NFKD" psq '&#1055;&#1088;&#1080; ＡＢ №5' '5+при+ａｂ+'
ffi() { # ffi <file> <expected output>
  [ "$("$T/ffi_parse" "$1")" = "$2" ]
}
check "ffi parses scope, lib, typedef, enum values" ffi "$SRC/mayhem/ffi/testsuite/decls.h" \
  "$(printf '%s\n%s' 'file: scope=example lib=libexample.so static_lib= types=5 typedefs=1 BLUE=6 GREEN=5 RED=0 err= line=0' \
                      'type: none err=syntax error, unexpected end of file')"
check "ffi parses a type expression" ffi "$SRC/mayhem/ffi/testsuite/type.txt" \
  "$(printf '%s\n%s' 'file: scope= lib= static_lib= types=0 typedefs=0 err=syntax error, unexpected end of file, expecting "," or ; line=1' \
                      'type: ok err=')"
printf 'int static x;' > "$W/static.h"
check "ffi rejects a misplaced storage class" ffi "$W/static.h" \
  "$(printf '%s\n%s' 'file: scope= lib= static_lib= types=0 typedefs=0 err=syntax error, unexpected STATIC, expecting ; or ( or * or IDENTIFIER line=1' \
                      'type: none err=syntax error, unexpected STATIC, expecting )')"
emit_ctrf "kphp-tl-golden" "$passed" "$failed" 0
