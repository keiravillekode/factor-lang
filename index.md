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
