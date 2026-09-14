#!/usr/bin/env python3
"""Delta-debugging minimizer over a finding's op list.

  reduce.py findings/ZIG_CRASH-123-debug [--timeout 120] [--tries-per-test 1]
            [--oracle PATH] [--image PATH] [--vm NAME=PATH ...]

Reads ops.json + flags.txt (line 1: VM flags, line 2: vm name), repeatedly
removes chunks of ops while the Zig VM still reproduces the same class and
signature (MISMATCH: oracle is re-run per candidate). Writes min.ops.json and
min.factor into the finding directory. Pass the same --vm options the
campaign used.
"""
import argparse
import json
import os
import shlex
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen  # noqa: E402
import run  # noqa: E402


def check(ops, vm, flags, want_cls, want_sig, timeout, tries, extended=None):
    src = gen.render(ops, extended)
    with tempfile.TemporaryDirectory(dir=run.TMPDIR) as td:
        prog = os.path.join(td, "cand.factor")
        with open(prog, "w") as f:
            f.write(src)
        oracle = run.run_vm(run.ORACLE, prog, timeout)
        if not run.oracle_ok(oracle):
            return False
        for _ in range(tries):
            res = run.run_vm(run.ZIG_VMS[vm] + flags, prog, timeout)
            cls, sig = run.classify(oracle, res)
            if cls == want_cls and (want_cls == "MISMATCH" or sig == want_sig):
                return True
    return False


def ddmin(ops, test):
    n = 2
    while len(ops) >= 2:
        chunk = max(1, len(ops) // n)
        reduced = False
        for i in range(0, len(ops), chunk):
            cand = ops[:i] + ops[i + chunk:]
            if cand and test(cand):
                print(f"  {len(ops)} -> {len(cand)} ops", flush=True)
                ops = cand
                n = max(n - 1, 2)
                reduced = True
                break
        if not reduced:
            if chunk == 1:
                break
            n = min(len(ops), n * 2)
    return ops


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("finding")
    ap.add_argument("--timeout", type=int, default=120)
    ap.add_argument("--tries-per-test", type=int, default=1)
    run.add_vm_args(ap)
    a = ap.parse_args()
    run.configure(a)
    d = a.finding
    with open(os.path.join(d, "ops.json")) as f:
        ops = json.load(f)
    lines = open(os.path.join(d, "flags.txt")).read().splitlines()
    flags, vm = shlex.split(lines[0]), lines[1]
    extended = True if len(lines) > 2 and lines[2] == "extended" else None
    if vm not in run.ZIG_VMS:
        print(f"cannot reduce {vm!r} findings (e.g. save-image reloads, or a --vm name not given); reduce by hand")
        return 1
    want_cls = os.path.basename(os.path.normpath(d)).split("-")[0]

    # Establish the reference signature by re-running the original.
    src = gen.render(ops, extended)
    with tempfile.TemporaryDirectory(dir=run.TMPDIR) as td:
        prog = os.path.join(td, "orig.factor")
        open(prog, "w").write(src)
        oracle = run.run_vm(run.ORACLE, prog, a.timeout)
        for _ in range(max(3, a.tries_per_test)):
            res = run.run_vm(run.ZIG_VMS[vm] + flags, prog, a.timeout)
            cls, sig = run.classify(oracle, res)
            if cls == want_cls:
                break
    print(f"original: {cls} {sig} ({len(ops)} ops)")
    if cls != want_cls:
        print("original does not reproduce; raise --tries-per-test")
        return 1

    test = lambda cand: check(cand, vm, flags, want_cls, sig, a.timeout, a.tries_per_test, extended)  # noqa: E731
    small = ddmin(ops, test)
    json.dump(small, open(os.path.join(d, "min.ops.json"), "w"), indent=1)
    open(os.path.join(d, "min.factor"), "w").write(gen.render(small, extended))
    print(f"minimized to {len(small)} ops -> {d}/min.factor")
    for o in small:
        print("   ", o)
    return 0


if __name__ == "__main__":
    sys.exit(main())
