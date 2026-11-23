// libFuzzer harness for KPHP's Unicode search-query normalizer (common/unicode).
//
// clean_str() is the whole body of the PHP builtin prepare_search_query()
// (runtime-common/stdlib/string/string-functions.h): it decodes the query as UTF-8 with HTML
// entities (html_string_to_utf8), case-folds / NFKD-maps / filters every code point through the
// generated tables, re-orders words and re-encodes the result as UTF-8. The buffers are sized
// exactly as the runtime sizes them (prepare_search_query_impl_ in string-functions.h), and the
// assert callback aborts like the runtime's php_assert. The code points are then also run through
// the vkext helpers the runtime uses on the same data (simplify_character, put_string_utf8).
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "common/unicode/unicode-utils.h"
#include "common/unicode/utf8-utils.h"

static void abort_assert(bool cond) {
  if (!cond) {
    abort();
  }
}

static int32_t code_points[MAX_NAME_CODE_POINTS_SIZE];
static size_t word_start_indices[MAX_NAME_CODE_POINTS_SIZE];
static int32_t prepared_code_points[MAX_NAME_CODE_POINTS_SIZE];
static std::byte utf8_result[MAX_NAME_BYTES_SIZE];

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size) {
  // PHP strings handed to the runtime are NUL-terminated; clean_str() works on the C string.
  std::vector<char> s(data, data + size);
  s.push_back('\0');
  size_t len = clean_str(s.data(), code_points, word_start_indices, prepared_code_points, utf8_result, abort_assert);
  abort_assert(len < MAX_NAME_BYTES_SIZE);

  // Plain UTF-8 decode (string_to_utf8_len), per-character simplification, and re-encode.
  size_t n = strlen(s.data());
  if (n < MAX_NAME_SIZE) {
    std::vector<int> v(n + 1);
    string_to_utf8_len(s.data(), static_cast<int>(n), v.data());
    for (size_t i = 0; v[i] != 0; i++) {
      v[i] = simplify_character(v[i]);
      (void)unicode_toupper(v[i], abort_assert);
      (void)unicode_tolower(v[i], abort_assert);
    }
    std::vector<char> out(4 * n + 4);
    put_string_utf8(v.data(), out.data());
  }
  return 0;
}
