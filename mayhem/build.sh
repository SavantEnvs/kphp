#!/usr/bin/env bash
#
# mayhem/build.sh — build KPHP's TL schema tools for fuzzing, plus the oracle used by mayhem/test.sh.
#
# Upstream's CMake build configures the whole KPHP tree (compiler, runtime and 12 third-party
# submodules) even for the small TL tools, so this script compiles exactly the sources upstream's
# CMake lists for them, with upstream's own compile flags (cmake/init-compilation-flags.cmake):
#   * tl-compiler   = common/tl/compiler/{tl-compiler,tl-parser-new}.cpp + popular-common
#                     (common/tl/compiler/tl-compiler.cmake, cmake/popular-common.cmake)
#   * tlo_parsing   = common/tlo-parsing/*.cpp (common/tlo-parsing/tlo-parsing.cmake)
#   * ffi           = compiler/ffi/*.cpp + c_parser/*.cpp (committed generated lexer/parser; KPHP_COMPILER_FFI_SOURCES)
#   * unicode       = common/unicode/{unicode-utils,utf8-utils}.cpp + generated tables (common/unicode/unicode.cmake)
#   * php-lexer     = compiler/lexer.cpp + gperf-generated keywords_set.hpp (compiler/compiler.cmake), fmt 7.0.3
# Nothing is downloaded (fmt and gperf come from the image); the build is re-runnable and works offline.
#
# Outputs (all under the gitignored mayhem/build/):
#   mayhem/build/bin/tl-compiler            AFL-instrumented CLI, ASan+UBSan  (target tl-compiler)
#   mayhem/build/bin/tlo_dump               AFL-instrumented .tlo reader, ASan+UBSan (target tlo-parsing)
#   mayhem/build/bin/unicode_fuzz(-standalone)  libFuzzer harness over common/unicode (target unicode)
#   mayhem/build/bin/ffi_parse              AFL-instrumented FFI C-declaration parser (target ffi)
#   mayhem/build/bin/php_lexer_fuzz(-standalone)  libFuzzer harness over the PHP lexer (target php-lexer)
#   mayhem/build/test/{tl-compiler,tlo_dump,prepare_search_query,ffi_parse}   normal-flag build for mayhem/test.sh
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
B="$SRC/mayhem/build"
mkdir -p "$B/bin" "$B/test"

case "$(uname -m)" in
  x86_64)  ARCH=x86_64;  MARCH=-march=sandybridge ;;
  aarch64) ARCH=aarch64; MARCH=-march=armv8.2-a+crypto ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac

# Upstream's global compile options (cmake/init-compilation-flags.cmake), minus -Werror.
UPSTREAM_FLAGS="-std=c++17 -fwrapv -fno-strict-aliasing -fno-stack-protector -fno-common -fsigned-char $MARCH -I$SRC -D_GNU_SOURCE"
VERSION_DEFS=(-DCOMMIT="\"mayhem\"" -DBUILD_TIMESTAMP=0 -DCMAKE_CXX_COMPILER_ID_STR="\"Clang\"" -DCMAKE_CXX_COMPILER_VERSION_STR="\"\"")

POPULAR_COMMON=(algorithms/simd-int-to-string.cpp resolver.cpp precise-time.cpp cpuid.cpp crc32_generic.cpp
  crc32.cpp crc32c.cpp options.cpp secure-bzero.cpp "crc32_${ARCH}.cpp" "crc32c_${ARCH}.cpp" version-string.cpp
  kernel-version.cpp kprintf.cpp rpc-headers.cpp parallel/counter.cpp parallel/maximum.cpp parallel/thread-id.cpp
  parallel/limit-counter.cpp server/limits.cpp server/signals.cpp server/relogin.cpp server/crash-dump.cpp
  server/engine-settings.cpp stats/buffer.cpp stats/provider.cpp)
POPULAR_COMMON=("${POPULAR_COMMON[@]/#/common/}")
TLC_SRCS=(common/tl/compiler/tl-compiler.cpp common/tl/compiler/tl-parser-new.cpp "${POPULAR_COMMON[@]}")
TLO_SRCS=(common/tlo-parsing/flat-optimization.cpp common/tlo-parsing/remove-odd-types.cpp
  common/tlo-parsing/replace-anonymous-args.cpp common/tlo-parsing/tl-dependency-graph.cpp
  common/tlo-parsing/tl-objects.cpp common/tlo-parsing/tl-scheme-final-check.cpp common/tlo-parsing/tlo-parser.cpp)

# compile <compiler> <objdir> <flags...> -- <sources...>   (parallel; prints the object list on stdout)
compile() {
  local cxx="$1" od="$2"; shift 2
  local flags=() ; while [ "$1" != "--" ]; do flags+=("$1"); shift; done; shift
  mkdir -p "$od"
  local pids=() objs=() n=0 s o
  for s in "$@"; do
    o="$od/$(echo "$s" | tr '/' '_').o"
    objs+=("$o")
    local extra=()
    [ "$s" = common/version-string.cpp ] && extra=("${VERSION_DEFS[@]}")
    "$cxx" "${flags[@]}" "${extra[@]}" -c "$s" -o "$o" >&2 &
    pids+=($!); n=$((n+1))
    if [ "$n" -ge "$MAYHEM_JOBS" ]; then for p in "${pids[@]}"; do wait "$p"; done; pids=(); n=0; fi
  done
  for p in "${pids[@]}"; do wait "$p"; done
  for o in "${objs[@]}"; do [ -f "$o" ] || { echo "missing $o" >&2; return 1; }; done
  printf '%s\n' "${objs[@]}"
}

FUZZ_CXXFLAGS=(-O1 $UPSTREAM_FLAGS $SANITIZER_FLAGS $DEBUG_FLAGS)
rm -rf "$B/obj-afl" "$B/obj-lex" "$B/obj-lex-sa" "$B/obj-test" "$B/obj-uni" "$B/obj-uni-sa" "$B/obj-afl-ffi" "$B/obj-test-ffi" "$B/bin" && mkdir -p "$B/bin"

# LSan off for every sanitized binary (SPEC §6.2 item 15).
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$B/lsan_off.o"

# 1) tlo-parsing: mayhem/tlo_dump.cpp (parse_tlo + the KPHP compiler's passes on one .tlo file),
#    AFL-instrumented, library and driver under ASan+UBSan. parse_tlo's API takes a file path and the
#    reader asserts on any truncated input (tlo_parser::check_pos), so a file-input AFL program fits
#    better than a libFuzzer harness, which would stop at that first abort.
AFL_CXX="${AFL_CXX:-afl-clang-fast++}"
mapfile -t TLO_AFL_OBJS < <(compile "$AFL_CXX" "$B/obj-afl" "${FUZZ_CXXFLAGS[@]}" -- "${TLO_SRCS[@]}")
"$AFL_CXX" "${FUZZ_CXXFLAGS[@]}" "$SRC/mayhem/tlo_dump.cpp" "${TLO_AFL_OBJS[@]}" "$B/lsan_off.o" -o "$B/bin/tlo_dump"

# 2) tl-compiler: upstream's CLI, AFL-instrumented (it keeps global parser state and exit()s on errors,
#    so it is fuzzed as a file-input program, one schema file per execution).
mapfile -t TLC_AFL_OBJS < <(compile "$AFL_CXX" "$B/obj-afl" "${FUZZ_CXXFLAGS[@]}" -- "${TLC_SRCS[@]}")
"$AFL_CXX" "${FUZZ_CXXFLAGS[@]}" "${TLC_AFL_OBJS[@]}" "$B/lsan_off.o" -lpthread -o "$B/bin/tl-compiler"

# 3) unicode: libFuzzer harness mayhem/unicode_fuzz.cpp over common/unicode (clean_str = the PHP
#    builtin prepare_search_query, plus the vkext UTF-8 helpers). The lookup tables are generated the
#    way common/unicode/unicode.cmake does it, from the committed raw_data/unicode-data.tgz, into
#    mayhem/build/auto (gitignored, re-created on every run).
U="$B/auto"
rm -rf "$U" && mkdir -p "$U/common/unicode/raw_data" "$U/common/unicode/data" "$B/tools"
$CXX -O2 -std=c++17 -D_GNU_SOURCE common/unicode/prepare-unicode-data.cpp -o "$B/tools/prepare_unicode_data"
$CXX -O2 -std=c++17 -D_GNU_SOURCE common/unicode/generate-unicode-utils.cpp -o "$B/tools/generate_unicode_utils"
tar xzf common/unicode/raw_data/unicode-data.tgz -C "$U/common/unicode/raw_data/"
R="$U/common/unicode/raw_data"; D="$U/common/unicode/data"
"$B/tools/prepare_unicode_data" "$R/CaseFolding.txt" "$D/UnicodeCaseFolding.txt"
"$B/tools/prepare_unicode_data" "$R/GeneralCategory.txt" "$D/UnicodeGeneralCategory.txt"
"$B/tools/prepare_unicode_data" -c 0,13 "$R/UnicodeData.txt" "$D/UnicodeLowercase.txt"
"$B/tools/prepare_unicode_data" -c 0,12 "$R/UnicodeData.txt" "$D/UnicodeUppercase.txt"
"$B/tools/prepare_unicode_data" -a -c 0,5 "$R/UnicodeData.txt" "$D/UnicodeNFKD.txt"
"$B/tools/generate_unicode_utils" "$D/UnicodeCaseFolding.txt" "$D/UnicodeGeneralCategory.txt" "$D/UnicodeNFKD.txt" \
  "$D/UnicodeUppercase.txt" "$D/UnicodeLowercase.txt" "$U/common/unicode-utils-auto.h"
UNI_SRCS=(common/unicode/unicode-utils.cpp common/unicode/utf8-utils.cpp)
# libFuzzer binary: project + harness with SanCov (fuzzer-no-link); the -standalone reproducer is a
# separate compile without SanCov, so it also links with an empty SANITIZER_FLAGS.
mapfile -t UNI_OBJS < <(compile "$CXX" "$B/obj-uni" "${FUZZ_CXXFLAGS[@]}" -fsanitize=fuzzer-no-link "-I$B" -- "${UNI_SRCS[@]}" mayhem/unicode_fuzz.cpp)
$CXX "${FUZZ_CXXFLAGS[@]}" $LIB_FUZZING_ENGINE "${UNI_OBJS[@]}" "$B/lsan_off.o" -o "$B/bin/unicode_fuzz"
mapfile -t UNI_SA_OBJS < <(compile "$CXX" "$B/obj-uni-sa" "${FUZZ_CXXFLAGS[@]}" "-I$B" -- "${UNI_SRCS[@]}" mayhem/unicode_fuzz.cpp)
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$B/standalone_main.o"
$CXX "${FUZZ_CXXFLAGS[@]}" "${UNI_SA_OBJS[@]}" "$B/standalone_main.o" "$B/lsan_off.o" -o "$B/bin/unicode_fuzz-standalone"

# 4) ffi: mayhem/ffi_parse.cpp over the compiler's FFI C-declaration parser (compiler/ffi: preprocessor,
#    committed ragel lexer + bison parser, ParsingDriver, FFIType). AFL file-input program (see the
#    driver's header for why not libFuzzer). ffi_parser.cpp's includes of compiler-core.h /
#    compiler-settings.h (only for the verbosity setting) resolve to mayhem/ffi-shim via -iquote.
FFI_SRCS=(compiler/ffi/ffi_parser.cpp compiler/ffi/ffi_types.cpp compiler/ffi/c_parser/lexer_generated.cpp
  compiler/ffi/c_parser/parsing_driver.cpp compiler/ffi/c_parser/yy_parser_generated.cpp)
FFI_FLAGS=(-iquote "$SRC/mayhem/ffi-shim")
mapfile -t FFI_AFL_OBJS < <(compile "$AFL_CXX" "$B/obj-afl-ffi" "${FUZZ_CXXFLAGS[@]}" "${FFI_FLAGS[@]}" -- "${FFI_SRCS[@]}" mayhem/ffi_parse.cpp)
"$AFL_CXX" "${FUZZ_CXXFLAGS[@]}" "${FFI_AFL_OBJS[@]}" "$B/lsan_off.o" -o "$B/bin/ffi_parse"

# 4b) php-lexer: libFuzzer harness mayhem/php_lexer_fuzz.cpp over the compiler's PHP lexer
#     (php_text_to_tokens + phpdoc_to_tokens, compiler/lexer.cpp). keywords_set.hpp is generated with
#     upstream's gperf command (compiler/compiler.cmake) into mayhem/build/auto (gitignored); fmt is
#     upstream's pinned 7.0.3 (cmake/external-libraries.cmake), header-only from the image.
: "${FMT_DIR:=/opt/toolchains/deps/fmt-7.0.3/src}"
mkdir -p "$U/compiler"
gperf -CGD -c -N get_type -Z KeywordsSet -K keyword -L C++ -t compiler/keywords.gperf > "$U/compiler/keywords_set.hpp"
LEX_FLAGS=("-I$B" -isystem "$FMT_DIR/include" -DFMT_HEADER_ONLY)
mapfile -t LEX_OBJS < <(compile "$CXX" "$B/obj-lex" "${FUZZ_CXXFLAGS[@]}" -fsanitize=fuzzer-no-link "${LEX_FLAGS[@]}" -- compiler/lexer.cpp mayhem/php_lexer_fuzz.cpp)
$CXX "${FUZZ_CXXFLAGS[@]}" $LIB_FUZZING_ENGINE "${LEX_OBJS[@]}" "$B/lsan_off.o" -o "$B/bin/php_lexer_fuzz"
mapfile -t LEX_SA_OBJS < <(compile "$CXX" "$B/obj-lex-sa" "${FUZZ_CXXFLAGS[@]}" "${LEX_FLAGS[@]}" -- compiler/lexer.cpp mayhem/php_lexer_fuzz.cpp)
$CXX "${FUZZ_CXXFLAGS[@]}" "${LEX_SA_OBJS[@]}" "$B/standalone_main.o" "$B/lsan_off.o" -o "$B/bin/php_lexer_fuzz-standalone"

# 5) Normal-flag build for the oracle (mayhem/test.sh): upstream's tl-compiler and a .tlo dumper.
TEST_CXXFLAGS=(-O2 $UPSTREAM_FLAGS $COVERAGE_FLAGS)
mapfile -t TLC_OBJS < <(compile "$CXX" "$B/obj-test" "${TEST_CXXFLAGS[@]}" -- "${TLC_SRCS[@]}" "${TLO_SRCS[@]}")
TLC_ONLY=() ; TLO_ONLY=()
for o in "${TLC_OBJS[@]}"; do case "$o" in *tlo-parsing*) TLO_ONLY+=("$o") ;; *) TLC_ONLY+=("$o") ;; esac; done
$CXX "${TEST_CXXFLAGS[@]}" "${TLC_ONLY[@]}" -lpthread -o "$B/test/tl-compiler"
$CXX "${TEST_CXXFLAGS[@]}" "$SRC/mayhem/tlo_dump.cpp" "${TLO_ONLY[@]}" -o "$B/test/tlo_dump"
mapfile -t UNI_TEST_OBJS < <(compile "$CXX" "$B/obj-test" "${TEST_CXXFLAGS[@]}" "-I$B" -- "${UNI_SRCS[@]}")
$CXX "${TEST_CXXFLAGS[@]}" "-I$B" "$SRC/mayhem/prepare_search_query.cpp" "${UNI_TEST_OBJS[@]}" -o "$B/test/prepare_search_query"
mapfile -t FFI_TEST_OBJS < <(compile "$CXX" "$B/obj-test-ffi" "${TEST_CXXFLAGS[@]}" "${FFI_FLAGS[@]}" -- "${FFI_SRCS[@]}" mayhem/ffi_parse.cpp)
$CXX "${TEST_CXXFLAGS[@]}" "${FFI_TEST_OBJS[@]}" -o "$B/test/ffi_parse"

ls -l "$B/bin" "$B/test"
