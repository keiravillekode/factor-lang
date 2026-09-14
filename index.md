# Factor investigation notes

Findings from investigating the Factor VM, shared with the Factor team.

## Windows ARM64: faults inside VM primitives are unrecoverable

The `build-windows-arm` CI job fails in `core/kernel/kernel-tests.factor` at
`[ f 0 alien-unsigned-1 ] [ vm-error? ] must-fail-with`. This is not caused
by the PRs it appears on.

- **Cause:** VM primitives are entered through the assembly stub `trampoline`,
  which has no Windows unwind data. When a primitive's C++ code faults,
  Windows cannot unwind back to the Factor frame whose exception handler would
  turn the fault into a `vm-error`, so the process dies with `0xC0000005`.
- **Contents:** the write-up has the diagnostic CI runs, unwind walks, and
  two candidate fixes, each tested on CI (including faults through
  `trampoline2`, used for FFI calls with stack arguments), for the team to
  choose between.

**[Read the write-up](windows-arm64-seh.md)**

## Zig VM: differential GC fuzzing

The `zig-vm-fuzzing` branch adds a fuzzer for the Zig VM that runs random
GC-heavy Factor programs on it and on the C++ VM, and compares the output.
It also adds GC stress flags to the Zig VM (`-gc-zeal`, `-gc-zeal-code`,
`-nursery-budget`, `-verify-heap`).

- **Found:** the three Zig VM fixes in
  [#3211](https://github.com/factor/factor/pull/3211),
  [#3212](https://github.com/factor/factor/pull/3212) and
  [#3213](https://github.com/factor/factor/pull/3213). With each fix
  reverted, the fuzzer detects the bug again.
- **Contents:** setup, running and reading a campaign, which flags catch
  which bug, and pitfalls. It is not `zig build --fuzz`.

**[Read the guide](fuzz-testing.md)**

## Zig VM: format-float returns an empty string on Linux

On glibc the Zig VM's `(format-float)` returns an empty byte-array for
every call, so `sprintf` with `%f` or `%e` fails, and 41 `formatting`
tests fail. The C++ VM is unaffected.

- **Cause:** the Linux `LC_ALL_MASK` in `src/primitives/math.zig` is
  `0xFFF`, which glibc's `newlocale` rejects with `EINVAL` (glibc's mask is
  `0x1FBF`).
- **Contents:** a reproduction, the cause, and a one-line fix on the
  `zig-vm-format-float-locale` branch.

**[Read the bug report](zig-vm-format-float-locale.md)**
