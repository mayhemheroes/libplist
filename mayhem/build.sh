#!/usr/bin/env bash
#
# mayhem/build.sh — build libplist's four upstream libFuzzer harnesses + the test suite.
#
#   /mayhem/out/bplist_fuzzer   sanitized+libFuzzer -> target bplist_fuzzer (plist_from_bin)
#   /mayhem/out/xplist_fuzzer   sanitized+libFuzzer -> target xplist_fuzzer (plist_from_xml)
#   /mayhem/out/jplist_fuzzer   sanitized+libFuzzer -> target jplist_fuzzer (plist_from_json)
#   /mayhem/out/oplist_fuzzer   sanitized+libFuzzer -> target oplist_fuzzer (plist_from_openstep)
#   /mayhem/out/<f>-standalone  run-once reproducers (STANDALONE_FUZZ_MAIN, no libFuzzer runtime)
#   build-tests/                normal-flags autotools build; mayhem/test.sh runs `make check` there
#
# Upstream is autotools; autogen.sh only runs autoreconf locally (no network), so the
# build is air-gapped. The sanitized in-tree build produces src/.libs/libplist-2.0.a
# (libcnary convenience objects included); the harnesses link it statically.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

NOCONFIGURE=1 ./autogen.sh

# 1) Sanitized static library (out-of-tree, keeps srcdir pristine for the test build) —
#    the fuzzed code itself is instrumented. -fsanitize=fuzzer-no-link adds SanitizerCoverage
#    to the LIBRARY objects so libFuzzer/Mayhem get coverage feedback from the parser code
#    itself (without it only the harness is instrumented → ~1 edge).
FUZZ_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
mkdir -p build-fuzz
( cd build-fuzz
  ../configure --without-cython --enable-static --disable-shared \
      CC="$CC" CXX="$CXX" \
      CFLAGS="$FUZZ_FLAGS" \
      CXXFLAGS="$FUZZ_FLAGS"
  make -j"$MAYHEM_JOBS"
)

# 2) Harnesses: fuzzer + standalone run-once reproducer per harness.
mkdir -p "$SRC/out"
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
for f in bplist_fuzzer xplist_fuzzer jplist_fuzzer oplist_fuzzer; do
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++11 -Iinclude/ \
      "fuzz/$f.cc" -o "$SRC/out/$f" \
      $LIB_FUZZING_ENGINE build-fuzz/src/.libs/libplist-2.0.a
  # standalone links the coverage-instrumented library, so it needs the sancov runtime
  # (libclang_rt.fuzzer_no_main via -fsanitize=fuzzer-no-link) — StandaloneFuzzTargetMain.c
  # supplies main(), the runtime supplies the __sanitizer_cov_* hooks, no libFuzzer loop.
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS -std=c++11 -Iinclude/ \
      "fuzz/$f.cc" /tmp/standalone_main.o -o "$SRC/out/$f-standalone" \
      build-fuzz/src/.libs/libplist-2.0.a
done

# 3) Test suite: a clean out-of-tree build with the project's NORMAL flags, so
#    mayhem/test.sh is an honest functional oracle. `make check TESTS=` compiles
#    the check programs without running the suite; test.sh runs it.
mkdir -p build-tests
( cd build-tests
  ../configure --without-cython CFLAGS="-O2 $COVERAGE_FLAGS" CXXFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
  make -j"$MAYHEM_JOBS"
  make -j"$MAYHEM_JOBS" -C test check TESTS=
)

echo "build.sh: built out/{b,x,j,o}plist_fuzzer (+standalones) and build-tests/"
