#include "atomic-cl-64.hpp"

namespace factor {

#define ESP Sp
#define EIP Pc

// trampoline and trampoline2 are run from copies in the code heap's SEH area
// rather than from the executable: the copies are covered by the function
// table registered in c_to_factor_toplevel, so Windows can unwind from a
// faulting VM primitive back into Factor code and reach exception_handler.
// See write_arm64_trampoline_stubs in os-windows-arm.64.cpp.
const cell arm64_trampoline_stubs_offset = 0xf00;
const cell arm64_trampoline_stub_size = 6 * 4;
const cell arm64_trampoline_stubs_size = 2 * arm64_trampoline_stub_size;

inline static cell arm64_trampoline_address(char* seh_area) {
  return (cell)seh_area + arm64_trampoline_stubs_offset;
}

inline static cell arm64_trampoline2_address(char* seh_area) {
  return (cell)seh_area + arm64_trampoline_stubs_offset +
         arm64_trampoline_stub_size;
}

void write_arm64_trampoline_stubs(char* seh_area);

inline static void flush_icache(cell start, cell len) {
  HANDLE proc = GetCurrentProcess();
  FlushInstructionCache(proc, (LPCVOID)start, len);
}

inline static unsigned int fpu_status(unsigned int status) {
  unsigned int r = 0;

  if (status & 0x01)
    r |= FP_TRAP_INVALID_OPERATION;
  if (status & 0x02)
    r |= FP_TRAP_ZERO_DIVIDE;
  if (status & 0x04)
    r |= FP_TRAP_OVERFLOW;
  if (status & 0x08)
    r |= FP_TRAP_UNDERFLOW;
  if (status & 0x10)
    r |= FP_TRAP_INEXACT;

  return r;
}

}
