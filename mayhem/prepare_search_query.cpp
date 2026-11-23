// Oracle driver for mayhem/test.sh: prints clean_str(argv[1]) — the result of the PHP builtin
// prepare_search_query() — built with the project's normal flags.
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "common/unicode/unicode-utils.h"

static void abort_assert(bool cond) {
  if (!cond) {
    abort();
  }
}

static int32_t code_points[MAX_NAME_CODE_POINTS_SIZE];
static size_t word_start_indices[MAX_NAME_CODE_POINTS_SIZE];
static int32_t prepared_code_points[MAX_NAME_CODE_POINTS_SIZE];
static std::byte utf8_result[MAX_NAME_BYTES_SIZE];

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <query>\n", argv[0]);
    return 2;
  }
  size_t len = clean_str(argv[1], code_points, word_start_indices, prepared_code_points, utf8_result, abort_assert);
  fwrite(utf8_result, 1, len, stdout);
  fputc('\n', stdout);
  return 0;
}
