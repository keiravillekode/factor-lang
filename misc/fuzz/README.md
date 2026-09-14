# Zig VM differential GC fuzzer

Random GC-heavy Factor programs, run on Zig VM builds (Debug and ReleaseSafe)
and on the C++ VM as oracle, all loading the same `factor.image`. The output
digests must match. This is a plain Python driver, not `zig build --fuzz`.

Setup (Linux x86-64 tested; Zig 0.16):

    ./build.sh net-bootstrap                            # factor.image
    ZIG=/path/to/zig-0.16/zig misc/fuzz/build-vms.sh    # vms/factor-cpp, vms/debug, vms/safe
    misc/fuzz/run.py --start 0 --count 100 --jobs 8
    misc/fuzz/run.py --start 1000 --count 48 --jobs 8 --vms safe --timeout 400 \
        --zig-flags "-gc-zeal=100 -gc-zeal-code=25 -nursery-budget=128"

Stress flags are slow: a seed takes ~3 s on ReleaseSafe without them, ~50 s
with the flags above, and ~7 min with `-gc-zeal=20 -gc-zeal-code=10
-nursery-budget=64 -verify-heap=200`. Debug is roughly 2-3x slower again.
Raise `--timeout` to match, or TIMEOUT hides everything.

- `gen.py --seed N -o prog.factor [--ops-out ops.json]` generates one program.
  The program is a fixed prelude plus independent, type-guarded ops, each with
  stack effect `( -- )`: allocation, including large objects; old→young
  mutation; `minor-gc`, `gc` and `compact-gc`; valid `become`; continuations
  and callstack objects; deep recursion; runtime `define-declared` and
  redefinition; curried and composed `call(`; green threads; displaced
  aliens; and sorting. The program prints `C:` checkpoint lines, `D:` pool
  summaries and `FUZZ-DONE`.
- `run.py --start 0 --count 200 --jobs 8 [--zig-flags "..."] [--vms debug,safe]`
  runs a campaign with random `-young=1..4 -aging=1..8` (and sometimes
  `-tenured=` or `-codeheap=`) per seed. Each result is PASS, ZIG_CRASH,
  MISMATCH, TIMEOUT or ORACLE_FAIL. ORACLE_FAIL is a generator bug, not a VM
  finding. Failures go to `findings/<CLASS>-<seed>-<vm>/`, all records to
  `results.jsonl`, and a table of deduplicated signatures is printed at the
  end. The exit status is 1 if any seed did not PASS.
  `--oracle`, `--image` and `--vm NAME=PATH` (repeatable) point at other
  binaries, e.g. a VM built from another checkout.
- `--zig-flags` passes the Zig VM's GC stress flags (all off by default):
  `-gc-zeal=N` (nursery GC before every Nth VM-side allocation),
  `-gc-zeal-code=N` (compacting GC before every Nth code block allocation),
  `-nursery-budget=KB` (usable nursery after each GC, minimum 64) and
  `-verify-heap[=N]` (check heap invariants after every Nth GC; violations
  panic with `verify-heap: <check>: ...`). Write a single flag as
  `--zig-flags=-gc-zeal=5`; argparse rejects `--zig-flags -gc-zeal=5`.
- `--extended` (on `gen.py` and `run.py`) adds opt-in op families (off by
  default; default programs are unchanged byte for byte). All extended prelude
  words are prefixed `xf-`:
  1. tuple redefinition with live instances (`xf-rt`, reshaped via
     `"TUPLE: ..." eval( -- )`; slot `k` survives every redefinition and is
     the only slot read), exercising `update-tuples` -> `become`;
  2. generic `xf-g` dispatched over 9 receiver classes from compiled words,
     base-JIT `call(`s and `dyn` words (cold -> IC -> PIC -> megamorphic),
     with methods (re)defined mid-run via `M: ... eval( -- )`;
  3. save-image + reload: `run.py --extended --save-image-every N` makes every
     Nth seed save an image (`FUZZ_SAVE_IMAGE`) on each VM, reload it with
     `-i=<image> -e='USING: fuzzprog ; dump'` and compare the digest with the
     oracle's run (records `<vm>-reload`; at most 2 seeds hold images at once,
     skipped below 4 GB free, images deleted afterwards);
  4. libc `qsort` via `FUNCTION-ALIAS:` with `CALLBACK:` comparators that
     allocate, GC (`minor-gc`/`gc`), allocate large objects, and sort again
     from inside the callback (2 and 3 levels of nesting), on malloc'd memory;
  5. the sampling profiler (`profile`) at 7..3001 samples/s around allocation,
     GC and `yield`; profile data is touched but never digested.
- `reduce.py findings/<dir>` runs delta debugging over `ops.json` while the
  same class and signature still reproduce. It writes `min.factor` and
  `min.ops.json`. Pass the same `--vm` options the campaign used.

Notes: both VMs exit 1 on a Factor error *and* on a critical error, so
classification uses output markers, not exit codes. `make` and `zig build`
both overwrite `./factor`; `build-vms.sh` restores it.

The C++ `resize-array` fills grown slots with fixnum 0, while the Zig VM uses
f as the docs say; the generator normalizes this.

`reduce.py` keeps the extended prelude for extended findings (`flags.txt`
line 3); `*-reload` findings need two launches and must be reduced by hand.
