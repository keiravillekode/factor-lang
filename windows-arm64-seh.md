# Windows ARM64: VM primitive faults are unrecoverable

Investigation of the `build-windows-arm` CI failure (C++ VM), 2026-09-13/14.
Upstream code links are pinned to
[`df18f5dc27`](https://github.com/factor/factor/commit/df18f5dc2734bfec84185166800b8b39d825a59b)
(upstream `master` at the time); line numbers drift after that.

## Summary

- The `test` step of `build-windows-arm` dies with exit code `-1073741819`
  (`0xC0000005`, access violation) at
  [`core/kernel/kernel-tests.factor:206`](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/core/kernel/kernel-tests.factor#L206):
  `[ f 0 alien-unsigned-1 ] [ vm-error? ] must-fail-with`.
- It is **pre-existing and unrelated to the PRs it shows up on**. The job was
  added in [`3e517bffb0`](https://github.com/factor/factor/commit/3e517bffb0f49f17576c3545da98e14abfac6ee5)
  (2026-07-07) and has never passed the `test` step.
- **Root cause:** on Windows ARM64, VM primitives are entered through the
  assembly stub `trampoline`, which has **no Windows unwind data**. When a
  primitive's C++ code faults, Windows cannot unwind past the trampoline to
  the Factor frame whose registered handler would turn the fault into a
  `vm-error`, so the exception is unhandled and the process dies.
- Faults inside JIT-compiled Factor code *are* recovered on Windows ARM64. The
  code-heap function table, the unwind data for Factor frames, and
  `exception_handler`'s context redirect all work.

## Upstream CI evidence

| Run | Context | Result |
|---|---|---|
| [34751031286 / job 103707489855](https://github.com/factor/factor/actions/runs/34751031286/job/103707489855) | PR #3211 (`zig-vm-resetTenuredCards`, Zig-only change) | `test` fails at kernel-tests:206 |
| [34755253961 / job 103718424414](https://github.com/factor/factor/actions/runs/34755253961/job/103718424414) | [PR #3212](https://github.com/factor/factor/pull/3212) (Zig-only change) | `test` fails; the other 5 platforms pass |
| [34556559334 / job 103130354589](https://github.com/factor/factor/actions/runs/34556559334/job/103130354589) | `master`, 2026-09-11 | `test` fails at kernel-tests:206 |
| [28982255532 / job 86003472234](https://github.com/factor/factor/actions/runs/28982255532/job/86003472234) | `master`, 2026-07-08, first run of the job | `test` fails (log ends earlier, in the hashtable tests) |

The job
([`build.yml` L89-L113](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/.github/workflows/build.yml#L89-L113))
builds the **C++ VM** with `build.cmd`, so Zig VM changes (`src/*.zig`) cannot
affect it. Linux ARM64 and macOS ARM64 pass the same test.

## How Windows ARM64 exception handling is set up

- [`vm/os-windows-arm.64.cpp` `c_to_factor_toplevel` (L27-L65)](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/os-windows-arm.64.cpp#L27-L65)
  registers the code heap with `RtlAddFunctionTable`:
  - the table covers the heap in 1 MB fragments, starting after the SEH area
    ([`vm/code_heap.hpp` L4](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/code_heap.hpp#L4),
    [`vm/code_heap.cpp` L26](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/code_heap.cpp#L26));
  - each fragment uses the unwind code
    [`0xe3e481e1` (L5)](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/os-windows-arm.64.cpp#L5)
    (`stp fp, lr, [sp, #-16]!; mov fp, sp`);
  - the attached handler trampolines to `exception_handler`.
- [`vm/os-windows.cpp` `exception_handler` (L201-L253)](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/os-windows.cpp#L201-L253)
  calls `dispatch_signal_handler` with the fault context's `Sp`/`Pc`
  ([`ESP`/`EIP` macros](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/os-windows-arm.64.hpp#L5-L6)).
- The bootstrap assembler switches the TEB stack base/limit to the Factor
  callstack
  ([`arm.windows.factor` L10-L24](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/basis/bootstrap/assembler/arm.windows.factor#L10-L24)).

Windows finds this handler only by **unwinding** from the fault to a code-heap
frame. Linux and macOS never unwind: the signal handler redirects directly from
the signal context
([`vm/cpu-arm.64.cpp` L30-L43](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/cpu-arm.64.cpp#L30-L43)).

### Primitive calls go through `trampoline`

- The base-JIT primitive template does `f LDR=BLR*`
  ([`arm.64.factor` L18-L25](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/basis/bootstrap/assembler/arm.64.factor#L18-L25)).
- `LDR=BLR*` expands to `IP0 3 insns LDR TRAMPOLINE BLR`
  ([`assembler.factor` L687-L697](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/basis/cpu/arm/64/assembler/assembler.factor#L687-L697)).
  FFI calls use `TRAMPOLINE`/`TRAMPOLINE2` as well
  ([`64.factor` L860-L884](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/basis/cpu/arm/64/64.factor#L860-L884)).
- The `RT_TRAMPOLINE` relocations resolve to `&factor::trampoline` inside the
  executable
  ([`code_blocks.cpp` L256-L259](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/code_blocks.cpp#L256-L259),
  [`contexts.hpp` L78-L79](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/contexts.hpp#L78-L79)).
- The stubs are plain armasm64 with no unwind annotations
  ([`vm/cpu-arm.64-trampoline.asm`](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/cpu-arm.64-trampoline.asm#L10-L24)),
  assembled by
  [`Nmakefile` L160-L161](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/Nmakefile#L160-L161):

  ```
  trampoline
      STP FP, LR, [SP, -16]!
      MOV FP, SP
      STR FP, [X20]   ; ctx.callstack_top
      BLR X16         ; the primitive / C function
      LDP FP, LR, [SP], 16
      RET
  ```

For comparison, the x86-64 primitive template calls the primitive directly
(`RAX CALL`,
[`x86.64.factor` L75-L81](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/basis/bootstrap/assembler/x86.64.factor#L75-L81)),
so there is no un-annotated frame between the C++ function and the code heap.
x86-64 Windows registers one frameless entry for the whole segment
([`os-windows-x86.64.cpp` L28-L81](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/os-windows-x86.64.cpp#L28-L81)).

## Diagnostic runs (fork, not a PR)

Branch
[`win-arm-seh-diagnostics`](https://github.com/keiravillekode/factor-lang/tree/win-arm-seh-diagnostics)
on [keiravillekode/factor-lang](https://github.com/keiravillekode/factor-lang).
Its own workflow
[`win-arm-diag.yml`](https://github.com/keiravillekode/factor-lang/blob/2aa3c28516726e9edb33ac7c0e0293c532074d69/.github/workflows/win-arm-diag.yml)
runs only on that branch, on a single `windows-11-arm` job: build, bootstrap,
two null-read scripts, then the kernel tests. It skips `load-all`, so a run
takes about 10 minutes.

| Commit | Adds | Run |
|---|---|---|
| [`9fe6efab40`](https://github.com/keiravillekode/factor-lang/commit/9fe6efab40715e57dace22b86cc6c1742c893909) | See below | [34782429410 / job 103791756647](https://github.com/keiravillekode/factor-lang/actions/runs/34782429410/job/103791756647) |
| [`2aa3c28516`](https://github.com/keiravillekode/factor-lang/commit/2aa3c28516726e9edb33ac7c0e0293c532074d69) | See below | [34783872758 / job 103795690862](https://github.com/keiravillekode/factor-lang/actions/runs/34783872758/job/103795690862) |

Commit `9fe6efab40` adds:
- logging around `RtlAddFunctionTable` and `exception_handler`;
- a logging-only vectored exception handler (VEH) that records the exception
  code, PC/SP/FP/LR, whether each of PC and LR is in the code heap, and the
  `RtlLookupFunctionEntry` result for each;
- the [`null-compiled.factor`](https://github.com/keiravillekode/factor-lang/blob/2aa3c28516726e9edb33ac7c0e0293c532074d69/misc/win-arm-diag/null-compiled.factor)
  and [`null-primitive.factor`](https://github.com/keiravillekode/factor-lang/blob/2aa3c28516726e9edb33ac7c0e0293c532074d69/misc/win-arm-diag/null-primitive.factor)
  scripts.

Commit `2aa3c28516` adds:
- a VEH that repeats the dispatcher's frame walk
  (`RtlLookupFunctionEntry` + `RtlVirtualUnwind`) for faults outside the code
  heap;
- raw TEB `StackBase`/`StackLimit` logging;
- skipping MSVC C++ exceptions (`0xe06d7363`) in the VEH log.

### Run 1: fault in JIT code is fine, fault in a primitive is fatal

| Script | Fault location | `exception_handler` entered? | Outcome |
|---|---|---|---|
| `null-compiled.factor` (optimized word; `alien-unsigned-1` is an intrinsic) | code heap | yes; redirect `signal_resumable=1` | `caught { 64199 16 0 f }`, exit 0 |
| `null-primitive.factor` (quotation built at run time, base-JIT primitive call) | `factor.exe` (C++ primitive) | **no** | exit `0xC0000005` |
| kernel tests | code heap (several faults), then `f 0 alien-unsigned-1` | yes for the code-heap faults; no log for the last | dies at kernel-tests:206 |

`RtlAddFunctionTable` succeeded (96 entries), and `RtlLookupFunctionEntry`
finds Factor's entries for code-heap PCs.

### Run 2: the unwind walk stops in `trampoline`

For `null-primitive.factor`:

```
VEH #1 code=0xc0000005 addr=00007FF7DD81661C access=0 target=0x0
  pc=0x7ff7dd81661c sp=0x1980df50ea0 fp=0x1980df50ec0 lr=0x7ff7dd81661c pc_in_code_heap=0
  TEB StackBase=000001980DF51000 StackLimit=000001980DE51000      (= Factor callstack segment)
  walk[0] pc=0x7ff7dd81661c in_code_heap=0 entry=00007FF7DD8BC2E0 base=0x7ff7dd810000 begin=0x6608
  walk[0] unwound: establisher=0x1980df50ec0 handler=0 -> pc=0x7ff7dd811010 sp=0x1980df50ec0
  walk[1] pc=0x7ff7dd811010 in_code_heap=0 entry=0000000000000000 base=0x7ff7dd810000
  walk[1] no function entry, leaf rule pc<-lr
  walk stopped: no progress
```

1. The faulting C++ function (`factor.exe+0x6608`) has unwind data and unwinds
   correctly.
2. Its return address is `factor.exe+0x1010`, which has **no function entry**.
   Windows applies the leaf rule (return address = LR), but LR is that same
   address, so the walk cannot advance. The code-heap frame and its handler are
   never reached.
3. `+0x1010` is `trampoline` just after its `BLR`. `trampoline` is 4
   instructions starting at `+0x1000` (`STP`, `MOV`, `STR`, `BLR`, i.e.
   `0x1000`-`0x100c`). armasm64's plain `.text` section is linked ahead of
   MSVC's `.text$mn`, so it lands at the start of the image. That placement is
   inferred, not confirmed from a linker map; the primitive call path above
   independently shows `trampoline` is the caller.

Ruled out along the way:
- **Stack bounds.** The TEB limits equal the Factor callstack segment, and the
  handled code-heap faults have SP in the same segment.
- **A registration or redirect problem.** Code-heap faults are handled
  end-to-end.

## Fix options

### Option 1: unwind annotations for the trampolines

Rewrite `vm/cpu-arm.64-trampoline.asm` with Microsoft's ARM64 prologue/epilogue
macros from `kxarm64.h`, so the linker emits `.pdata`/`.xdata` for the stubs:

```
    NESTED_ENTRY trampoline
    PROLOG_SAVE_REG_PAIR fp, lr, #-16!
    PROLOG_SET_FP
    STR FP, [X20]
    BLR X16
    EPILOG_RESTORE_REG_PAIR fp, lr, #16!
    EPILOG_RETURN
    NESTED_END trampoline
```

- **Pros:** the conventional Windows approach, contained in the assembly file
  and the build rule, with no VM logic changes.
- **Cons / open questions:**
  - Using `kxarm64.h` likely needs a C-preprocessor pass before `armasm64`
    (e.g. `cl /nologo /EP`), which means a change to
    [`Nmakefile` L160-L161](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/Nmakefile#L160-L161).
    The alternative is hand-writing the `.pdata`/`.xdata` records.
  - `trampoline2` saves FP/LR at `[IP1]` (`X17`, the caller's frame area
    computed in `%c-invoke-tramp2`) rather than below SP. The standard
    prologue macros can't describe that exactly: an `fp`-based description
    would recover SP as `IP1 + 16`, not the caller's real SP. That is probably
    harmless for Factor's handler, but needs checking, or custom unwind codes.

### Option 2: run the trampolines from the code heap

Copy the trampoline instructions into code-heap memory covered by the table
that `c_to_factor_toplevel` already registers, and resolve
`RT_TRAMPOLINE`/`RT_TRAMPOLINE2` to the copy instead of `&factor::trampoline`.
The registered fragments use exactly `trampoline`'s prologue
(`stp fp, lr, [sp, #-16]!; mov fp, sp`) and carry the handler, so the unwind
reaches a frame with the handler.

- **Pros:** no toolchain or `Nmakefile` change; reuses unwind data that is
  already known to work (code-heap faults are handled).
- **Cons / open questions:**
  - It needs more VM code: allocate and fill a stub in executable,
    function-table-covered memory in
    [`os-windows-arm.64.cpp`](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/os-windows-arm.64.cpp#L27-L65),
    and change the relocation targets in
    [`code_blocks.cpp` L256-L259](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/vm/code_blocks.cpp#L256-L259)
    (Windows ARM64 only).
  - The SEH area itself is not covered by the table (it starts at
    `base + seh_area_size`), so the stub must live in a covered fragment or
    the table must be extended.
  - The same `trampoline2` SP caveat applies.
  - The copy must stay put through code-heap compaction, or be re-resolved.

### Results: both options fix the crash

Both branches build on the diagnostics (shared commit
[`3c53036d23`](https://github.com/keiravillekode/factor-lang/commit/3c53036d23)
adds them to the workflow trigger).

| Option | Branch / commit | Run | `null-primitive.factor` | kernel tests |
|---|---|---|---|---|
| 1: unwind annotations | [`win-arm-seh-option1-unwind-annotations`](https://github.com/keiravillekode/factor-lang/tree/win-arm-seh-option1-unwind-annotations) / [`75f0e07292`](https://github.com/keiravillekode/factor-lang/commit/75f0e07292) | [34792479410 / job 103819177176](https://github.com/keiravillekode/factor-lang/actions/runs/34792479410/job/103819177176) | `caught { 64199 16 0 f }`, exit 0 | 60 unit + 18 must-fail, both `alien-unsigned-1` tests pass, exit 0 |
| 2: code-heap trampolines | [`win-arm-seh-option2-code-heap-trampolines`](https://github.com/keiravillekode/factor-lang/tree/win-arm-seh-option2-code-heap-trampolines) / [`12f6b2e2b0`](https://github.com/keiravillekode/factor-lang/commit/12f6b2e2b0) | [34792479332 / job 103819176915](https://github.com/keiravillekode/factor-lang/actions/runs/34792479332/job/103819176915) | `caught { 64199 16 0 f }`, exit 0 | 60 unit + 18 must-fail, both `alien-unsigned-1` tests pass, exit 0 |

The unwind walk shows each mechanism working as intended.

Option 1: `trampoline` now has a function entry in the image (`begin=0x1000`),
so the walk continues into the code heap.

```
walk[0] pc=…662c entry=… begin=0x6618 -> unwound to pc=…1014
walk[1] pc=…1014 entry=… begin=0x1000 -> unwound to pc=0x27a530ab850
walk[2] in_code_heap=1 -> walk reached the code heap
exception_handler entered ... ; [diag] primitive: caught { 64199 16 0 f }
```

Option 2: the return address is the stub copy in the SEH area, covered by the
new function-table entry 0 (`begin=0xf00`).

```
walk[0] pc=…663c entry=… begin=0x6628 -> unwound to pc=0x15c60001f10
walk[1] pc=0x15c60001f10 in_code_heap=1 entry=… begin=0xf00 -> walk reached the code heap
exception_handler entered ... ; [diag] primitive: caught { 64199 16 0 f }
```

For option 1, the build log confirms the new rule ran:
`cl /nologo /P /EP /TC /Fivm\cpu-arm.64-trampoline.i.asm …`, then
`armasm64 … vm\cpu-arm.64-trampoline.i.asm`.

Not yet covered by these runs:
- the CI job's full `test` step (`tools.test resource:core`) after `load-all`,
  and `help-lint`;
- a fault inside a C function reached through `trampoline2` (FFI with stack
  arguments). Option 1 leaves that path without unwind data; option 2 covers
  it, with an approximate unwound SP.

### Faults through `trampoline2`

Test commit (identical on both branches) adds:
- `win_arm_diag_read1` / `win_arm_diag_read9` to `vm/os-windows.cpp`. Each is
  a C function exported from the VM that reads the address passed in its last
  argument. With 9 arguments the 9th goes on the stack, so the compiler calls
  through `%c-invoke-tramp2`.
- Three scripts, each run as its own step:
  - `ffi-read-trampoline.factor`: `win_arm_diag_read1` on address 0
    (control, through `trampoline`);
  - `ffi-read-trampoline2.factor`: `win_arm_diag_read9` on address 0 (fault
    in C, reached through `trampoline2`);
  - `ffi-null-indirect-trampoline2.factor`: `alien-indirect` with 9 arguments
    to address 0 (fault at pc 0, return address in `trampoline2`).
- The workflow trigger `'win-arm-seh-**'`.

`{ 64199 16 … }` is a memory-protection `vm-error`, so the fault really
happened. `{ 64199 9 … }` would mean the symbol lookup failed.

| Option | Branch / commit | Run | `ffi-read-trampoline` | `ffi-read-trampoline2` | `ffi-null-indirect-trampoline2` |
|---|---|---|---|---|---|
| 1 | [`win-arm-seh-option1-trampoline2-test`](https://github.com/keiravillekode/factor-lang/tree/win-arm-seh-option1-trampoline2-test) / [`346940cb9a`](https://github.com/keiravillekode/factor-lang/commit/346940cb9a) | [34794334205](https://github.com/keiravillekode/factor-lang/actions/runs/34794334205) — **no result**: "The hosted runner lost communication with the server" after 48 min in `bootstrap`; no log available | not run | not run | not run |
| 1 (retry) | [`win-arm-seh-option1-trampoline2-retry`](https://github.com/keiravillekode/factor-lang/tree/win-arm-seh-option1-trampoline2-retry) → same commit `346940cb9a` | [34797065699 / job 103832114511](https://github.com/keiravillekode/factor-lang/actions/runs/34797065699/job/103832114511) | caught `{ 64199 16 0 f }`, exit 0 | **not recovered**: exit `-1073741819` (`0xC0000005`) | **not recovered**: exit `-1073741819` (`0xC0000005`) |

The option 1 retry passed every earlier check (null reads in optimized code
and in a C++ primitive, kernel tests). The `trampoline2` faults were not
recovered, and the walk shows why: the return address in `trampoline2`
(`factor.exe+0x102c`) has no function entry, and the leaf rule makes no
progress, the same failure mode as the original `trampoline` bug.

```
ffi-read-trampoline (control, trampoline has unwind data in option 1):
  walk[0] pc=…2c60 entry=0, leaf rule pc<-lr
  walk[1] pc=…1014 entry=… begin=0x1000 -> unwound to the code heap
  walk[2] in_code_heap=1 -> walk reached the code heap; caught { 64199 16 0 f }
ffi-read-trampoline2:
  walk[0] pc=…2c6c entry=0, leaf rule pc<-lr
  walk[1] pc=0x7ff76689102c entry=0, leaf rule pc<-lr
  walk stopped: no progress; exit -1073741819
ffi-null-indirect-trampoline2:
  walk[0] pc=0x0 entry=0, leaf rule pc<-lr
  walk[1] pc=0x7ff76689102c entry=0, leaf rule pc<-lr
  walk stopped: no progress; exit -1073741819
```

The return addresses fit the option 1 object layout.

- `trampoline` starts at `+0x1000`, and its return address is `+0x1014`, so
  its `blr x16` is the 5th instruction. The `PROLOG_SAVE_REG_PAIR fp, lr`
  macro therefore emitted `stp` plus its own `mov fp, sp`, making the explicit
  `PROLOG_NOP mov fp, sp` a redundant (harmless) duplicate. That makes 7
  instructions, `+0x1000`–`+0x1018`.
- `trampoline2` then starts at `+0x101c`, and its `blr x16` (4th instruction)
  returns to `+0x102c`, the address where both walks stop.

This is inferred from the addresses, not confirmed from a map file.

**Summary of `trampoline2` evidence:**

| Fault reached through | Option 1 (unwind annotations) | Option 2 (code-heap trampolines) |
|---|---|---|
| VM primitive via `trampoline` | recovered | recovered |
| FFI C function via `trampoline` (≤ 8 arguments) | recovered | recovered |
| FFI C function via `trampoline2` (stack arguments) | **process dies** | recovered |
| `alien-indirect` to address 0 via `trampoline2` | **process dies** | recovered |
| 2 | [`win-arm-seh-option2-trampoline2-test`](https://github.com/keiravillekode/factor-lang/tree/win-arm-seh-option2-trampoline2-test) / [`5e521bb418`](https://github.com/keiravillekode/factor-lang/commit/5e521bb418) | [34794334051 / job 103824420557](https://github.com/keiravillekode/factor-lang/actions/runs/34794334051/job/103824420557) | caught `{ 64199 16 0 f }`, exit 0 | caught `{ 64199 16 0 f }`, exit 0 | caught `{ 64199 16 0 f }`, exit 0 |

The option 2 unwind walks for the three FFI steps show the same pattern each
time.

1. The fault PC has no function entry. The small `win_arm_diag_read*` leaf
   functions have no `.pdata`, and PC 0 has no image at all. Windows applies
   the leaf rule and takes PC from LR.
2. LR is the return address inside the stub copy in the code heap
   (`…1f10` for `trampoline` at `0xf00 + 0x10`, `…1f28` for `trampoline2` at
   `0xf18 + 0x10`), which is covered by function-table entry 0
   (`begin=0xf00`).
3. The walk reaches the code heap, `exception_handler` is entered, and the
   script prints `caught` and `after`.

```
ffi-read-trampoline2:
  walk[0] pc=0x7ff6f47d2c7c entry=0 (no unwind data), leaf rule pc<-lr
  walk[1] pc=0x2816e001f28 in_code_heap=1 begin=0xf00 -> walk reached the code heap
ffi-null-indirect-trampoline2:
  walk[0] pc=0x0 entry=0, leaf rule pc<-lr
  walk[1] pc=0x13181001f28 in_code_heap=1 begin=0xf00 -> walk reached the code heap
```

The option 2 run also repeated the earlier results: `null-primitive.factor`
was caught, and the kernel tests passed.

### Verification for either option

Push to `win-arm-seh-diagnostics`. Success is:
- `null-primitive.factor` prints `[diag] primitive: caught …`;
- the kernel tests pass kernel-tests:206 (and the
  `[ 1 <alien> 0 alien-unsigned-1 ]` test after it);
- the run-2 walk log reaches `walk reached the code heap`.

After that, the diagnostics can be dropped and only the fix proposed upstream.
