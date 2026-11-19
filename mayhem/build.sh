#!/usr/bin/env bash
#
# mayhem/build.sh — build osm2pgsql's fuzz harnesses (sanitized) and its DB-free test suite (normal flags).
#
#   build/fuzz   osm2pgsql_lib (+ osm2pgsql-expire) with $SANITIZER_FLAGS $DEBUG_FLAGS -> harnesses
#   build/tests  the upstream catch2 tests labelled NoDB, upstream's default flags -> mayhem/test.sh
#
# Both build dirs live under build/, which upstream's .gitignore covers (SPEC §6.2 item 16).
# All dependencies are apt -dev packages installed by mayhem/Dockerfile or vendored in contrib/
# (libosmium, protozero, fmt, CLI11, catch2), so the build is offline and re-runnable.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Every fuzzed object gets SanitizerCoverage so the fuzzer sees the project's edges, not just the harness's.
FUZZ_CFLAGS="-O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"

# 1) The project, sanitized + instrumented. CMAKE_BUILD_TYPE=Fuzz is a custom type with no flags of its
#    own, so upstream's RelWithDebInfo default (-O2 -g, i.e. DWARF 5) does not override -gdwarf-3.
#    WITH_PROJ=OFF: only EPSG:4326/3857 are needed, which osm2pgsql implements itself.
cmake -S . -B build/fuzz \
  -DCMAKE_BUILD_TYPE=Fuzz \
  -DBUILD_TESTS=OFF -DWITH_PROJ=OFF \
  -DCMAKE_C_FLAGS="$FUZZ_CFLAGS" \
  -DCMAKE_CXX_FLAGS="$FUZZ_CFLAGS"
cmake --build build/fuzz -j"$MAYHEM_JOBS" --target osm2pgsql_lib osm2pgsql-expire

# Compile flags and link libraries exactly as upstream's CMake resolved them for osm2pgsql-expire.
FLAGS_MAKE=build/fuzz/CMakeFiles/osm2pgsql-expire.dir/flags.make
LINK_TXT=build/fuzz/CMakeFiles/osm2pgsql-expire.dir/link.txt
DEFINES=$(sed -n 's/^CXX_DEFINES = //p' "$FLAGS_MAKE")
INCLUDES=$(sed -n 's/^CXX_INCLUDES = //p' "$FLAGS_MAKE")
LIBS=$(sed -e 's/.*libosm2pgsql\.a//' "$LINK_TXT")
LIB="$SRC/build/fuzz/src/libosm2pgsql.a"

# 2) Harnesses: libFuzzer binary + run-once standalone reproducer each.
H="$SRC/mayhem/harnesses"
O="$SRC/build/fuzz/harness-objs"
mkdir -p "$O"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$O/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$O/standalone_main.o"

build_harness() { # <name> <source> [extra compile flags...]
  local name="$1" src="$2"; shift 2
  # shellcheck disable=SC2086
  $CXX -std=c++17 $FUZZ_CFLAGS $DEFINES $INCLUDES -I"$SRC/src" "$@" -c "$src" -o "$O/$name.o"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$O/$name.o" "$O/lsan_off.o" "$LIB" $LIBS \
    -o "$SRC/mayhem/$name"
  # shellcheck disable=SC2086
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$O/$name.o" "$O/standalone_main.o" "$O/lsan_off.o" "$LIB" $LIBS \
    -o "$SRC/mayhem/$name-standalone"
}

build_harness fuzz_expire_pbf "$H/fuzz_expire.cpp" -DFUZZ_FORMAT='"pbf"'
build_harness fuzz_expire_xml "$H/fuzz_expire.cpp" -DFUZZ_FORMAT='"osm"'
build_harness fuzz_expire_opl "$H/fuzz_expire.cpp" -DFUZZ_FORMAT='"opl"'
build_harness fuzz_expire_o5m "$H/fuzz_expire.cpp" -DFUZZ_FORMAT='"o5m"'
build_harness fuzz_ewkb       "$H/fuzz_ewkb.cpp"
build_harness fuzz_style      "$H/fuzz_style.cpp"
build_harness fuzz_cmdline    "$H/fuzz_cmdline.cpp"

# 3) Upstream test suite (the NoDB-labelled catch2 tests), with upstream's normal flags.
NODB_TESTS=$(sed -n 's/^ *set_test(\(test-[a-z0-9-]*\) LABELS NoDB).*/\1/p' tests/CMakeLists.txt)
cmake -S . -B build/tests \
  -DBUILD_TESTS=ON -DWITH_PROJ=OFF \
  -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
# shellcheck disable=SC2086
cmake --build build/tests -j"$MAYHEM_JOBS" --target $NODB_TESTS
