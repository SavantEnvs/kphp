// Built twice by mayhem/build.sh: AFL+ASan+UBSan as the tlo-parsing fuzz target, and with normal
// flags as the mayhem/test.sh oracle helper. Parses a .tlo, run the compiler's
// passes, print a summary and the schema text so test.sh can diff it against a golden file.
#include <cstdio>
#include <exception>

#include "common/tlo-parsing/tl-objects.h"
#include "common/tlo-parsing/tlo-parsing.h"

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s file.tlo\n", argv[0]);
    return 2;
  }
  auto res = vk::tlo_parsing::parse_tlo(argv[1], true);
  if (!res.parsed_schema) {
    printf("error: %s", res.error.c_str());
    return 1;
  }
  auto& s = *res.parsed_schema;
  printf("version %d types %zu functions %zu magics %zu\n", s.scheme_version, s.types.size(), s.functions.size(), s.magics.size());
  try {
    vk::tlo_parsing::replace_anonymous_args(s);
    vk::tlo_parsing::perform_flat_optimization(s);
    vk::tlo_parsing::tl_scheme_final_check(s);
  } catch (const std::exception& e) {
    printf("final-check: %s\n", e.what());
    return 1;
  }
  printf("after-passes types %zu functions %zu\n", s.types.size(), s.functions.size());
  fputs(s.to_str().c_str(), stdout);
  return 0;
}
