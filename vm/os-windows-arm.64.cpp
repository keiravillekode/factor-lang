#include "master.hpp"

namespace factor {

static const DWORD arm64_unwind_code_fplr_frame = 0xe3e481e1;
static const cell arm64_function_fragment_size = ((1 << 18) - 1) * 4;

struct arm64_unwind_info {
  DWORD header;
  DWORD unwind_codes;
  DWORD exception_handler;
};

struct arm64_seh_data {
  RUNTIME_FUNCTION funcs[(0x8000000 / arm64_function_fragment_size) + 2];
  arm64_unwind_info unwind[(0x8000000 / arm64_function_fragment_size) + 2];
  DWORD handler[4];
};

static void arm64_store_handler_trampoline(DWORD* code, cell handler) {
  // ldr x16, #8; br x16; .quad handler
  code[0] = 0x58000050;
  code[1] = 0xd61f0200;
  memcpy(&code[2], &handler, sizeof(cell));
}

// --- win-arm-diag: temporary diagnostics for the windows-11-arm CI crash in
// kernel-tests ([ f 0 alien-unsigned-1 ] [ vm-error? ] must-fail-with). ---

static LONG CALLBACK win_arm_diag_veh(PEXCEPTION_POINTERS p) {
  static int count = 0;
  if (count >= 25)
    return EXCEPTION_CONTINUE_SEARCH;
  count++;

  PEXCEPTION_RECORD e = p->ExceptionRecord;
  PCONTEXT c = p->ContextRecord;
  factor_vm* vm = current_vm_p();

  int pc_in_code_heap = vm && vm->code && vm->code->seg->in_segment_p((cell)c->Pc);
  int lr_in_code_heap = vm && vm->code && vm->code->seg->in_segment_p((cell)c->Lr);

  DWORD64 pc_base = 0;
  PRUNTIME_FUNCTION pc_fn = RtlLookupFunctionEntry(c->Pc, &pc_base, NULL);
  DWORD64 lr_base = 0;
  PRUNTIME_FUNCTION lr_fn = RtlLookupFunctionEntry(c->Lr, &lr_base, NULL);

  ULONG_PTR stack_low = 0, stack_high = 0;
  GetCurrentThreadStackLimits(&stack_low, &stack_high);

  fprintf(stderr,
          "[win-arm-diag] VEH #%d code=0x%08lx flags=0x%lx addr=%p "
          "access=%llu target=0x%llx\n"
          "[win-arm-diag]   pc=0x%llx sp=0x%llx fp=0x%llx lr=0x%llx "
          "pc_in_code_heap=%d lr_in_code_heap=%d\n"
          "[win-arm-diag]   RtlLookupFunctionEntry(pc)=%p base=0x%llx begin=0x%lx"
          " | (lr)=%p base=0x%llx begin=0x%lx\n"
          "[win-arm-diag]   thread stack=[0x%llx,0x%llx) factor callstack=[0x%llx,0x%llx)"
          " code heap=[0x%llx,0x%llx)\n",
          count, (unsigned long)e->ExceptionCode, (unsigned long)e->ExceptionFlags,
          e->ExceptionAddress,
          (unsigned long long)(e->NumberParameters > 0 ? e->ExceptionInformation[0] : 0),
          (unsigned long long)(e->NumberParameters > 1 ? e->ExceptionInformation[1] : 0),
          (unsigned long long)c->Pc, (unsigned long long)c->Sp,
          (unsigned long long)c->Fp, (unsigned long long)c->Lr,
          pc_in_code_heap, lr_in_code_heap,
          (void*)pc_fn, (unsigned long long)pc_base,
          (unsigned long)(pc_fn ? pc_fn->BeginAddress : 0),
          (void*)lr_fn, (unsigned long long)lr_base,
          (unsigned long)(lr_fn ? lr_fn->BeginAddress : 0),
          (unsigned long long)stack_low, (unsigned long long)stack_high,
          (unsigned long long)(vm && vm->ctx ? vm->ctx->callstack_seg->start : 0),
          (unsigned long long)(vm && vm->ctx ? vm->ctx->callstack_seg->end : 0),
          (unsigned long long)(vm && vm->code ? vm->code->seg->start : 0),
          (unsigned long long)(vm && vm->code ? vm->code->seg->end : 0));
  fflush(stderr);
  return EXCEPTION_CONTINUE_SEARCH;
}

void factor_vm::c_to_factor_toplevel(cell quot) {
  arm64_seh_data* seh_area = (arm64_seh_data*)code->seh_area;
  cell base = code->seg->start;
  cell start = base + seh_area_size;
  cell end = code->seg->end;
  DWORD handler_rva = (DWORD)((cell)&seh_area->handler[0] - base);
  DWORD entry_count = 0;

  FACTOR_ASSERT(sizeof(arm64_seh_data) <= seh_area_size);
  arm64_store_handler_trampoline(
      seh_area->handler, (cell)&factor::exception_handler);

  for (cell fragment_start = start; fragment_start < end;
       fragment_start += arm64_function_fragment_size) {
    cell fragment_size = std::min(arm64_function_fragment_size,
                                  end - fragment_start);
    arm64_unwind_info* unwind = &seh_area->unwind[entry_count];
    RUNTIME_FUNCTION* func = &seh_area->funcs[entry_count];

    unwind->header =
      (DWORD)((fragment_size >> 2) | (1 << 20) | (1 << 27));
    unwind->unwind_codes = arm64_unwind_code_fplr_frame;
    unwind->exception_handler = handler_rva;

    func->BeginAddress = (DWORD)(fragment_start - base);
    func->UnwindData = (DWORD)((cell)unwind - base);

    entry_count++;
  }

  factor::flush_icache((cell)&seh_area->handler[0],
                       sizeof(seh_area->handler));

  static bool win_arm_diag_veh_installed = false;
  if (!win_arm_diag_veh_installed) {
    AddVectoredExceptionHandler(1, win_arm_diag_veh);
    win_arm_diag_veh_installed = true;
  }

  BOOLEAN added = RtlAddFunctionTable(seh_area->funcs, entry_count, base);
  fprintf(stderr,
          "[win-arm-diag] RtlAddFunctionTable=%d base=0x%llx start=0x%llx end=0x%llx "
          "entries=%lu handler=0x%llx exception_handler=%p "
          "unwind[0].header=0x%08lx unwind_codes=0x%08lx handler_rva=0x%lx "
          "funcs[0].begin=0x%lx\n",
          (int)added, (unsigned long long)base, (unsigned long long)start,
          (unsigned long long)end, (unsigned long)entry_count,
          (unsigned long long)(base + handler_rva), (void*)&factor::exception_handler,
          (unsigned long)seh_area->unwind[0].header,
          (unsigned long)seh_area->unwind[0].unwind_codes,
          (unsigned long)handler_rva, (unsigned long)seh_area->funcs[0].BeginAddress);
  fflush(stderr);
  if (!added)
    fatal_error("RtlAddFunctionTable() failed", 0);

  c_to_factor(quot);

  if (!RtlDeleteFunctionTable(seh_area->funcs))
    fatal_error("RtlDeleteFunctionTable() failed", 0);
}

}
