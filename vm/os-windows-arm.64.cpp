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

// Same instructions as vm/cpu-arm.64-trampoline.S. Both stubs start with the
// fp/lr frame that arm64_unwind_code_fplr_frame describes (trampoline2 keeps
// its frame at [x17], so the unwound sp is approximate, but fp/lr are right).
static const DWORD arm64_trampoline_stub_code[] = {
  // trampoline
  0xa9bf7bfd, // stp fp, lr, [sp, #-16]!
  0x910003fd, // mov fp, sp
  0xf900029d, // str fp, [x20]   ; ctx.callstack_top
  0xd63f0200, // blr x16
  0xa8c17bfd, // ldp fp, lr, [sp], #16
  0xd65f03c0, // ret
  // trampoline2
  0xa9007a3d, // stp fp, lr, [x17]
  0xaa1103fd, // mov fp, x17
  0xf900029d, // str fp, [x20]
  0xd63f0200, // blr x16
  0xa9407bbd, // ldp fp, lr, [fp]
  0xd65f03c0, // ret
};

// Called from the code_heap constructor, before any code block is relocated
// against RT_TRAMPOLINE/RT_TRAMPOLINE2.
void write_arm64_trampoline_stubs(char* seh_area) {
  if (sizeof(arm64_seh_data) > arm64_trampoline_stubs_offset ||
      sizeof(arm64_trampoline_stub_code) != arm64_trampoline_stubs_size ||
      arm64_trampoline_stubs_offset + arm64_trampoline_stubs_size > seh_area_size)
    fatal_error("arm64 trampoline stubs do not fit in the SEH area",
                sizeof(arm64_seh_data));
  memcpy(seh_area + arm64_trampoline_stubs_offset, arm64_trampoline_stub_code,
         sizeof(arm64_trampoline_stub_code));
  factor::flush_icache((cell)seh_area + arm64_trampoline_stubs_offset,
                       arm64_trampoline_stubs_size);
}

static void arm64_store_handler_trampoline(DWORD* code, cell handler) {
  // ldr x16, #8; br x16; .quad handler
  code[0] = 0x58000050;
  code[1] = 0xd61f0200;
  memcpy(&code[2], &handler, sizeof(cell));
}

// --- win-arm-diag: temporary diagnostics for the windows-11-arm CI crash in
// kernel-tests ([ f 0 alien-unsigned-1 ] [ vm-error? ] must-fail-with). ---

static LONG CALLBACK win_arm_diag_veh(PEXCEPTION_POINTERS p) {
  // MSVC C++ exceptions (0xe06d7363) are routine inside the VM; don't let
  // them use up the log budget.
  if (p->ExceptionRecord->ExceptionCode == 0xe06d7363)
    return EXCEPTION_CONTINUE_SEARCH;
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

  NT_TIB* tib = (NT_TIB*)NtCurrentTeb();
  fprintf(stderr, "[win-arm-diag]   TEB StackBase=%p StackLimit=%p\n",
          tib->StackBase, tib->StackLimit);

  // Repeat the dispatcher's frame walk from the fault context: for each frame,
  // is there a function entry, what does RtlVirtualUnwind produce, and is a
  // handler attached? Stops at the first code-heap frame (where Factor's
  // exception_handler is registered) or when the walk stops making progress.
  if (!pc_in_code_heap) {
    CONTEXT walk = *c;
    for (int frame = 0; frame < 12; frame++) {
      int in_code = vm && vm->code && vm->code->seg->in_segment_p((cell)walk.Pc);
      DWORD64 base = 0;
      PRUNTIME_FUNCTION fn = RtlLookupFunctionEntry(walk.Pc, &base, NULL);
      fprintf(stderr,
              "[win-arm-diag]   walk[%d] pc=0x%llx sp=0x%llx fp=0x%llx lr=0x%llx "
              "in_code_heap=%d entry=%p base=0x%llx begin=0x%lx\n",
              frame, (unsigned long long)walk.Pc, (unsigned long long)walk.Sp,
              (unsigned long long)walk.Fp, (unsigned long long)walk.Lr, in_code,
              (void*)fn, (unsigned long long)base,
              (unsigned long)(fn ? fn->BeginAddress : 0));
      if (in_code) {
        fprintf(stderr, "[win-arm-diag]   walk reached the code heap\n");
        break;
      }
      DWORD64 prev_pc = walk.Pc, prev_sp = walk.Sp;
      if (!fn) {
        // No unwind data: the dispatcher treats it as a leaf, pc <- lr.
        walk.Pc = walk.Lr;
        fprintf(stderr, "[win-arm-diag]   walk[%d] no function entry, leaf rule pc<-lr\n",
                frame);
      } else {
        PVOID handler_data = NULL;
        DWORD64 establisher = 0;
        PEXCEPTION_ROUTINE handler =
            RtlVirtualUnwind(UNW_FLAG_EHANDLER, base, prev_pc, fn, &walk,
                             &handler_data, &establisher, NULL);
        fprintf(stderr,
                "[win-arm-diag]   walk[%d] unwound: establisher=0x%llx handler=%p "
                "-> pc=0x%llx sp=0x%llx\n",
                frame, (unsigned long long)establisher, (void*)handler,
                (unsigned long long)walk.Pc, (unsigned long long)walk.Sp);
      }
      if (walk.Pc == 0 || (walk.Pc == prev_pc && walk.Sp == prev_sp)) {
        fprintf(stderr, "[win-arm-diag]   walk stopped: no progress\n");
        break;
      }
    }
  }
  fflush(stderr);
  return EXCEPTION_CONTINUE_SEARCH;
}

void factor_vm::c_to_factor_toplevel(cell quot) {
  arm64_seh_data* seh_area = (arm64_seh_data*)code->seh_area;
  cell base = code->seg->start;
  cell start = base + seh_area_size;
  cell end = code->seg->end;
  DWORD handler_rva = (DWORD)((cell)&seh_area->handler[0] - base);
  // Entry 0 covers the trampoline stubs (write_arm64_trampoline_stubs); they
  // begin with the same fp/lr frame as Factor code, so the same unwind code
  // and handler apply. Entries must be sorted, and the stubs lie below start.
  seh_area->unwind[0].header =
      (DWORD)((arm64_trampoline_stubs_size >> 2) | (1 << 20) | (1 << 27));
  seh_area->unwind[0].unwind_codes = arm64_unwind_code_fplr_frame;
  seh_area->unwind[0].exception_handler = handler_rva;
  seh_area->funcs[0].BeginAddress = (DWORD)arm64_trampoline_stubs_offset;
  seh_area->funcs[0].UnwindData = (DWORD)((cell)&seh_area->unwind[0] - base);
  DWORD entry_count = 1;

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
