# Fuzz testing the Zig VM

How to use the
[`zig-vm-fuzzing`](https://github.com/keiravillekode/factor-lang/tree/zig-vm-fuzzing)
branch of `keiravillekode/factor-lang` to fuzz the Zig VM, and what it
found. Written 2026-09-15. Upstream code links are pinned to
[`df18f5dc27`](https://github.com/factor/factor/commit/df18f5dc2734bfec84185166800b8b39d825a59b),
the `master` commit the branch is based on.

## Was this `zig build --fuzz`?

No. `zig build --fuzz` runs the `std.testing.fuzz` tests of a build's test
steps. `build.zig` has a `zig build test` step with ordinary unit tests but
no fuzz tests, and the bugs in question show up only while real Factor code
runs on a ~140 MB image and the GC moves objects.

What was used instead has two parts:

1. **A differential program fuzzer** (`misc/fuzz/`, Python). It generates
   random, GC-heavy but valid Factor programs from a seed. Each program runs
   on the C++ VM (the oracle) and on Zig VM builds, all loading the same
   `factor.image`. Their printed digests must match, and the Zig VM must not
   crash.
2. **GC stress flags in the Zig VM** (`src/`, off by default). They make GC
   happen far more often than normal, so a pointer left unrooted across an
   allocation, or a missing write barrier, fails at once. Without them such
   a bug fails only when a collection happens to hit it.

The fuzzer is not coverage-guided; it is seeded random generation plus
stress.

## What is on the branch

| Commit | Contents |
|---|---|
| [`ae3a281e0b`](https://github.com/keiravillekode/factor-lang/commit/ae3a281e0b) | Merge of the three fix branches: factor/factor PRs [#3213](https://github.com/factor/factor/pull/3213) (`passArgsToFactor-write-barrier`), [#3212](https://github.com/factor/factor/pull/3212) (`zig-vm-primitive_modify_code_heap`), [#3211](https://github.com/factor/factor/pull/3211) (`zig-vm-resetTenuredCards`) |
| [`4d7f065f89`](https://github.com/keiravillekode/factor-lang/commit/4d7f065f89) | `zig vm: GC stress and heap verification flags for fuzzing` — `src/gc.zig`, `image.zig`, `main.zig`, `vm.zig`, new `src/verify_heap.zig` |
| [`5f11d8c5b1`](https://github.com/keiravillekode/factor-lang/commit/5f11d8c5b1) | `misc/fuzz: differential GC fuzzer for the Zig VM` — `gen.py`, `run.py`, `reduce.py`, `build-vms.sh`, `README.md` |

### Zig VM flags

| Flag | Effect |
|---|---|
| `-gc-zeal=N` | nursery GC before every Nth VM-side allocation |
| `-gc-zeal-code=N` | compacting GC before every Nth code block allocation |
| `-nursery-budget=KB` | only KB of nursery usable after each GC (minimum 64), so compiled code falls into `minor_gc` often |
| `-verify-heap[=N]` | after every Nth GC, check heap invariants (object tiling, pointer targets, card/deck marks, code remembered sets, object-start maps); a violation panics with `verify-heap: <check>: ...` |

The C++ VM has none of these; they are passed only to the Zig VMs.

## Setup

Tested on Linux x86-64. You need Zig 0.16 (`build.zig.zon` requires it),
Python 3, and the usual C++ build tools.

```sh
git clone -b zig-vm-fuzzing https://github.com/keiravillekode/factor-lang.git
cd factor-lang
./build.sh net-bootstrap                          # C++ VM + factor.image
ZIG=/path/to/zig-0.16/zig misc/fuzz/build-vms.sh  # -> misc/fuzz/vms/
```

`build-vms.sh` produces:

- `misc/fuzz/vms/factor-cpp`: the C++ VM, the oracle
- `misc/fuzz/vms/debug/bin/factor`: the Zig VM, Debug
- `misc/fuzz/vms/safe/bin/factor`: the Zig VM, ReleaseSafe

Both `make` and `zig build` overwrite `./factor`; the script puts the
previous one back.

## Running a campaign

```sh
# plain: ~25 seeds/min on 12 cores, Debug + ReleaseSafe
misc/fuzz/run.py --start 0 --count 100 --jobs 8

# stress: ReleaseSafe only, long timeout
misc/fuzz/run.py --start 1000 --count 48 --jobs 6 --vms safe --timeout 400 \
    --zig-flags "-gc-zeal=100 -gc-zeal-code=25 -nursery-budget=128"

# one flag: use the = form, argparse rejects `--zig-flags -gc-zeal=5`
misc/fuzz/run.py --start 0 --count 4 --jobs 4 --zig-flags=-gc-zeal=5
```

Each seed also gets random `-young`, `-aging` and sometimes `-tenured` or
`-codeheap` sizes. Every run is classified as one of:

| Class | Meaning |
|---|---|
| `PASS` | digest matches the oracle |
| `ZIG_CRASH` | panic, fault, Factor error, or verifier message on the Zig VM |
| `MISMATCH` | Zig VM finished but printed different data |
| `TIMEOUT` | exceeded `--timeout` (Debug gets twice as long) |
| `ORACLE_FAIL` | the C++ VM failed: a generator bug, not a Zig VM finding |

Failures are saved to `misc/fuzz/findings/<CLASS>-<seed>-<vm>/`, with the
program, `ops.json`, the flags, and both VMs' stdout and stderr. Every
record is appended to `misc/fuzz/results.jsonl`. The run ends with a table
of deduplicated signatures, and exits 1 if anything did not pass.

Other useful options:

- `--extended` adds op families: tuple redefinition with live instances;
  generic dispatch through inline caches, PICs and megamorphic caches, with
  method redefinition; libc `qsort` with allocating and nesting callbacks;
  and the sampling profiler.
- `--save-image-every N` (with `--extended`) makes every Nth seed save an
  image and reload it on each VM.
- `--vm NAME=PATH` (repeatable), `--oracle` and `--image` run binaries from
  elsewhere, for example a VM built from another checkout or worktree.

To reproduce or minimize a finding:

```sh
F=misc/fuzz/findings/ZIG_CRASH-1007-safe
misc/fuzz/vms/safe/bin/factor -i=factor.image $(head -1 $F/flags.txt) $F/prog.factor
misc/fuzz/reduce.py $F    # -> min.factor
```

ReleaseSafe binaries are stripped and print "Cannot print stack trace".
For a trace, build with `zig build -Doptimize=ReleaseSafe
-Dkeep_symbols=true --prefix ...`, or use the Debug VM.

### Costs and pitfalls

- **Match the timeout to the flags.** A seed takes ~3 s on ReleaseSafe
  without flags and ~50 s with `-gc-zeal=100 -gc-zeal-code=25
  -nursery-budget=128`. With `-gc-zeal=20 -gc-zeal-code=10
  -nursery-budget=64 -verify-heap=200` it takes ~7 min, and Debug is 2–3×
  slower again. A 60 s timeout with the heavy set gave 48/48 TIMEOUT,
  which hides everything.
- **Some bugs appear only in some builds, or only under load.** The
  `resetTenuredCards` overflow panics only in ReleaseSafe, and only for some
  address-space layouts. The modify-code-heap stale pointer showed up more
  often with 6–8 jobs than serially. Run both builds, run in parallel, and
  re-run a finding several times before calling it fixed.
- **The oracle has a known quirk.** C++ `resize-array` fills grown slots
  with 0, while the Zig VM (and the docs) use `f`; the generator
  normalizes this.

## Recipes that catch the three fixed bugs

Each fix was reverted on its own, in a detached worktree (the reverts are
not on the branch), and fuzzed from the branch's harness via `--vm`. The
control is the same seeds and flags on the fixed branch.

| Bug (PR) | Recipe | With fix reverted | Control (fixed) |
|---|---|---|---|
| Missing write barrier storing argv aliens in `passArgsToFactor` ([#3213](https://github.com/factor/factor/pull/3213)) | `--zig-flags=-gc-zeal=5`, Debug + ReleaseSafe | **8/8 ZIG_CRASH** (seeds 0–3) within 4 s: `Memory protection fault during gc`, `Memory protection fault at address`, `Double fault` | Startup alone with `-gc-zeal=5 -e='"STARTUP-OK" print'`: revert 0/6 start, fixed 6/6 start |
| Stale `word_after` read after `jitCompileQuotation` in `primitive_modify_code_heap` ([#3212](https://github.com/factor/factor/pull/3212)) | `--vms safe --jobs 6 --timeout 400 --zig-flags "-gc-zeal=100 -gc-zeal-code=25 -nursery-budget=128"`, seeds 1000–1047 | **9/48 ZIG_CRASH**: `panic: reached unreachable code` | 48/48 PASS |
| Checked `+` on wrapping card/deck offsets in `resetTenuredCards` ([#3211](https://github.com/factor/factor/pull/3211)) | no stress flags, Debug + ReleaseSafe, seeds 0–23 | **ReleaseSafe 10/24 ZIG_CRASH**: `panic: integer overflow`; Debug 0/24 | 48/48 PASS |

Attribution:

- **#3213.** The reverted VM faults at address 0 in `init-resource-path`
  → `alien>string` while reading the argv aliens the missing barrier lost.
  The fixed VM starts every time.
- **#3211.** A symbolized ReleaseSafe build of the revert panicked at
  [`src/sweep.zig:224`](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/src/sweep.zig#L224)
  in `resetTenuredCards`, called from `sweepPhase` during a full GC.
- **#3212.** The campaign crash depends on timing: the seed 1007 finding
  did not re-crash in 4 parallel tries on a symbolized build. A targeted
  program run with `-gc-zeal-code=1` (a compacting GC before *every* code
  block allocation) does pin it down. On a symbolized ReleaseSafe build of
  the revert it panicked in `jitCompileQuotation`, called from
  [`src/primitives/code.zig:110`](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/src/primitives/code.zig#L110),
  which is `vm.jitCompileQuotation(word_after.pic_tail_def, false)`, the
  line the fix changes. The Debug build of the revert failed at the same
  call: its assertion `hasTag(quot_cell, .quotation)` shows that
  `pic_tail_def`, read through the moved word, is garbage. The program:

  ```factor
  USING: eval kernel io math prettyprint words ;
  IN: pictest
  : go ( -- )
      10 [ "IN: pictest GENERIC: zz ( x -- y ) M: fixnum zz 1 + ; M: object zz drop 0 ;" eval( -- ) ] times
      3 "zz" "pictest" lookup-word execute( x -- y ) . "PIC-DONE" print ;
  MAIN: go
  ```

  `-gc-zeal-code=1` is very slow: the revert crashed after ~6 min. The
  fixed ReleaseSafe build ran for 16 min without crashing or printing
  anything, and was killed before it finished. That makes it a weak
  control; the campaign control above is the stronger one. Use this flag
  on small programs, not on campaigns.

## Earlier campaigns

These ran in a separate checkout, before the harness moved into the branch:

- About 1,000 ReleaseSafe runs and 60 Debug runs under stress flags.
- The first two bugs were found by `-gc-zeal-code=25` (26 of 300 seeds
  crashed) and `-gc-zeal=5` (crashed at startup). The overflow was found by
  the plain ReleaseSafe runs.
- After the fixes: extended stress seeds 7000–7149, Debug stress seeds
  4000–4059 and verifier seeds 2000–2099 all came back clean.

That checkout also carried extra hardening assertions, which are not on the
fuzzing branch. They are on their own branch,
[`zig-vm-hardening-assertions`](https://github.com/keiravillekode/factor-lang/tree/zig-vm-hardening-assertions)
(off `master`):

- a root-stack canary at every GC entry: data-root capacity overflow in all
  build modes, and every root validated in Debug builds;
- `untagFixnumUnsigned` panics on a non-fixnum instead of returning 0; the
  low-level debugger uses a tolerant variant;
- `followForwardingPointers` panics on a chain of 16 or more hops instead
  of silently stopping;
- `assertPendingFlushed` in the compaction callstack walkers.

The branch is based on `master`, so it does not include the three fixes: its
ReleaseSafe VM still hits the `resetTenuredCards` overflow (7/24 plain seeds
crashed with `integer overflow`, Debug 24/24 passed). Merged onto
`zig-vm-fuzzing` it passes: 48/48 plain runs and 12/12 with
`-gc-zeal=100 -gc-zeal-code=25 -nursery-budget=128`. That merge conflicts in
`src/gc.zig`, where both branches add lines at the start of `gc()` and
`collectGrowingDataHeap`; keep both, the canary call and then
`hook_depth += 1; defer hook_depth -= 1;`.

The results in the recipes table were reproduced without these assertions.

Two differences were noted but not fixed:

- An invalid `become` is a `critical_error` in the Zig VM
  (`primitives/objects.zig`) but a type error in the C++ VM. The generator
  avoids it.
- The `resize-array` fill quirk described under Costs and pitfalls.
