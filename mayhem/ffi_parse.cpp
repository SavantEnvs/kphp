// File-input driver for KPHP's FFI C-declaration parser (compiler/ffi).
//
// The compiler hands the text of every FFI::cdef() string / FFI::load() header to ffi_parse_file()
// (preprocessor for FFI_SCOPE/FFI_LIB/FFI_STATIC_LIB, the ragel lexer, the bison grammar and the
// ParsingDriver that builds FFIType trees), and type expressions such as FFI::new("...") strings to
// ffi_parse_type(). This program parses one file both ways and prints what the parser returned.
//
// It is fuzzed as an AFL file-input program (one process per input) rather than a libFuzzer loop:
// like the compiler, the parser never frees what it allocates on an error path or what its typedef
// table points to (TypesAllocator::collect_garbage frees only unused nodes after a successful parse,
// and typedef targets can share members with the result), so an in-process loop would grow without
// bound and freeing those trees from a harness would risk harness-made double frees.
//
// on_compilation_error() is the compiler's error hook (compiler/kphp_assert.cpp): a kphp_assert in
// the parser is FATAL there (the compiler stops), so it aborts here; other levels are diagnostics.
//
// The normal-flag build of this file is also the oracle driver used by mayhem/test.sh.
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <iterator>
#include <string>

#include "compiler/ffi/ffi_parser.h"
#include "compiler/kphp_assert.h"

void on_compilation_error(const char* description, const char* file_name, int line_number, const char* full_description, AssertLevelT assert_level) {
  fprintf(stderr, "compilation error (level %d): %s at %s:%d: %s\n", static_cast<int>(assert_level), description, file_name, line_number, full_description);
  if (assert_level == FATAL_ASSERT_LEVEL) {
    abort();
  }
}

void on_compilation_error(const char* description, const char* file_name, int line_number, const std::string& full_description, AssertLevelT assert_level) {
  on_compilation_error(description, file_name, line_number, full_description.c_str(), assert_level);
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <file with C declarations>\n", argv[0]);
    return 2;
  }
  std::ifstream in(argv[1], std::ios::binary);
  if (!in) {
    fprintf(stderr, "cannot open %s\n", argv[1]);
    return 2;
  }
  std::string src((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());

  FFITypedefs typedefs;
  FFIParseResult result = ffi_parse_file(src, typedefs);
  printf("file: scope=%s lib=%s static_lib=%s types=%zu typedefs=%zu", result.scope.c_str(), result.lib.c_str(), result.static_lib.c_str(),
         result.num_types(), typedefs.size());
  for (const auto& [name, value] : result.enum_constants) {
    printf(" %s=%d", name.c_str(), value);
  }
  printf(" err=%s line=%d\n", result.err.message.c_str(), result.err.message.empty() ? 0 : result.err.line);

  FFITypedefs expr_typedefs;
  auto [type, err] = ffi_parse_type(src, expr_typedefs);
  printf("type: %s err=%s\n", type != nullptr ? "ok" : "none", err.message.c_str());
  return 0;
}
