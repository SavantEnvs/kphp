// libFuzzer harness for the KPHP compiler's PHP lexer (compiler/lexer.cpp).
//
// The compiler reads every .php file of a project into SrcFile::text and tokenizes it with
// php_text_to_tokens() (compiler/pipes/file-to-tokens.cpp); phpdoc comments are tokenized with
// phpdoc_to_tokens() (compiler/phpdoc.cpp). Both are called here on the input, after the one-time
// lexer_init() the compiler runs at startup (compiler/compiler.cpp). The lexer unescapes string
// literals IN PLACE in the source buffer (see the comment above LexerData::append_char), exactly as
// it does in SrcFile::text, so each input is first copied into a std::string that it may write to.
//
// on_compilation_error() is the compiler's error hook (compiler/kphp_assert.cpp): a kphp_assert is
// FATAL there (the compiler stops), so it aborts here; kphp_error/kphp_warning are diagnostics that
// let lexing continue, as in the compiler. stage::set_line/get_line are the only parts of the
// compiler's stage machinery the lexer uses (it records the line for error messages).
// LLVMFuzzerInitialize runs lexer_init() only, not k2_lexer_init() (the K2-mode `#ifndef K2` rule).
//
// State kept across inputs: the lexer singletons built by lexer_init() (rule tries, read-only after
// init) and the stage line number (overwritten before every use).
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "compiler/kphp_assert.h"
#include "compiler/lexer.h"
#include "compiler/location.h"

// compiler/location.h declares a debugger-only DEBUG_STRING_METHOD (kept by `used`) that calls
// Location::as_human_readable(), defined in compiler/location.cpp with the rest of the compiler's
// data model. The lexer never calls it; this definition only satisfies the link.
std::string Location::as_human_readable() const {
  return "line " + std::to_string(line);
}

namespace stage {
static int current_line = 0;
void set_line(int line) {
  current_line = line;
}
int get_line() {
  return current_line;
}
} // namespace stage

void on_compilation_error(const char* description, const char* file_name, int line_number, const char* full_description, AssertLevelT assert_level) {
  if (assert_level == FATAL_ASSERT_LEVEL) {
    fprintf(stderr, "kphp_assert failed: %s at %s:%d: %s\n", description, file_name, line_number, full_description);
    abort();
  }
}

extern "C" int LLVMFuzzerInitialize(int*, char***) {
  lexer_init();
  return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  // Built the way SrcFile::load() (compiler/data/src-file.cpp) builds SrcFile::text: a std::string
  // (so NUL-terminated) in which every zero byte of the file has been replaced by a space.
  std::string text(reinterpret_cast<const char*>(data), size);
  std::replace(text.begin(), text.end(), '\0', ' ');
  std::string doc = text;
  std::vector<Token> tokens = php_text_to_tokens(text);
  std::vector<Token> doc_tokens = phpdoc_to_tokens(doc);
  return 0;
}
