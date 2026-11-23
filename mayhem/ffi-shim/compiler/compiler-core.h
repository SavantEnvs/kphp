// Build shim for fuzzing compiler/ffi/ffi_parser.cpp outside the full KPHP compiler.
// ffi_parser.cpp only reads G->settings().verbosity (to log parser stats); the real
// compiler-core.h drags in the whole compiler (generated vertex headers, pipes, threads).
// This header stands in for it with a CompilerCore whose verbosity is 0, i.e. the default.
// It is found first only because build.sh puts mayhem/ffi-shim on the -iquote path.
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

struct MayhemShimVerbosity {
  uint64_t get() const noexcept {
    return 0;
  }
};
struct MayhemShimSettings {
  MayhemShimVerbosity verbosity;
};
struct MayhemShimCompilerCore {
  const MayhemShimSettings& settings() const noexcept {
    static const MayhemShimSettings s{};
    return s;
  }
};
inline MayhemShimCompilerCore mayhem_shim_compiler_core;
inline MayhemShimCompilerCore* G = &mayhem_shim_compiler_core;
