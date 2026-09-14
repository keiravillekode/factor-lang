#!/usr/bin/env python3
"""Differential fuzz campaign: Zig VMs vs the C++ VM as oracle.

  run.py --start 0 --count 200 [--jobs 8] [--zig-flags "-gc-zeal=100 -verify-heap"]
         [--timeout 60] [--extended [--save-image-every N]]
         [--oracle PATH] [--image PATH] [--vm NAME=PATH ...] [--vms debug,safe]

Classes: PASS, ZIG_CRASH, MISMATCH, TIMEOUT, ORACLE_FAIL (generator bug).
Failures are saved to findings/<CLASS>-<seed>-<vm>/ ; results appended to
results.jsonl. Binaries default to those made by build-vms.sh.
"""
import argparse
import collections
import concurrent.futures as cf
import contextlib
import json
import os
import random
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import gen  # noqa: E402

# Set by configure(): the oracle command, {name: command} for the Zig VMs,
# and the directory for temporary programs and images.
ORACLE = None
ZIG_VMS = {}
TMPDIR = None

# save-image seeds write ~140MB images per VM; bound disk use.
SAVE_SEM = threading.Semaphore(2)
SAVE_MIN_FREE = 4 * 2**30
RELOAD_E = "-e=USING: fuzzprog ; dump"

CRASH_RE = re.compile(
    r"(panic|critical_error|You have triggered a bug|Segmentation fault|"
    r"reached unreachable|integer overflow|index out of bounds|"
    r"attempt to use null|incorrect alignment|General protection|"
    r"fatal_error|Illegal instruction|Aborted|data_roots overflow|heap corruption|"
    r"verify|Memory protection fault)",
    re.IGNORECASE,
)


def add_vm_args(ap):
    vms = os.path.join(HERE, "vms")
    ap.add_argument("--oracle", default=os.path.join(vms, "factor-cpp"), help="C++ VM binary")
    ap.add_argument("--image", default=os.path.join(ROOT, "factor.image"), help="image run by every VM")
    ap.add_argument("--vm", action="append", default=[], metavar="NAME=PATH",
                    help="Zig VM binary (repeatable; default debug=vms/debug/bin/factor, safe=vms/safe/bin/factor)")
    ap.add_argument("--tmpdir", default=os.path.join(HERE, "work"), help="temporary programs and images")


def configure(args):
    global ORACLE, TMPDIR
    image = "-i=" + os.path.abspath(args.image)
    ORACLE = [os.path.abspath(args.oracle), image]
    vms = args.vm or [f"{name}={os.path.join(HERE, 'vms', name, 'bin', 'factor')}" for name in ("debug", "safe")]
    for spec in vms:
        name, sep, path = spec.partition("=")
        if not sep:
            sys.exit(f"--vm expects NAME=PATH, got {spec!r}")
        ZIG_VMS[name] = [os.path.abspath(path), image]
    TMPDIR = os.path.abspath(args.tmpdir)
    os.makedirs(TMPDIR, exist_ok=True)


def signature(text):
    for line in text.splitlines():
        if CRASH_RE.search(line):
            s = re.sub(r"0x[0-9a-fA-F]+", "0x?", line.strip())
            s = re.sub(r"\b\d{4,}\b", "N", s)
            return s[:200]
    return None


def digest(stdout):
    return [l for l in stdout.splitlines() if l.startswith(("D:", "C:", "FUZZ-DONE"))]


def run_vm(argv, prog, timeout, image_out=None):
    """image_out: extended programs save an image there (FUZZ_SAVE_IMAGE)."""
    t0 = time.time()
    env = None
    if image_out:
        env = dict(os.environ, FUZZ_SAVE_IMAGE=image_out)
    try:
        p = subprocess.run(argv + ([prog] if prog else []), stdin=subprocess.DEVNULL, capture_output=True,
                           timeout=timeout, cwd=ROOT, env=env)
        out = p.stdout.decode(errors="replace")
        err = p.stderr.decode(errors="replace")
        return dict(rc=p.returncode, out=out, err=err, timeout=False, secs=time.time() - t0)
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace")
        err = (e.stderr or b"").decode(errors="replace")
        return dict(rc=None, out=out, err=err, timeout=True, secs=time.time() - t0)


def oracle_ok(res):
    return (not res["timeout"]) and "FUZZ-DONE" in res["out"]


def pick_flags(rng):
    flags = [f"-young={rng.randint(1, 4)}", f"-aging={rng.randint(1, 8)}"]
    if rng.random() < 0.25:
        flags.append(f"-tenured={rng.randint(16, 64)}")
    if rng.random() < 0.25:
        # The image needs ~19MB of code heap; smaller values just fail to load,
        # and a nearly-full code heap panics (fail-stop) rather than fuzzing GC.
        flags.append(f"-codeheap={rng.randint(32, 64)}")
    return flags


def classify(oracle, res):
    text = res["out"] + "\n" + res["err"]
    if res["timeout"]:
        return "TIMEOUT", signature(text) or "timeout"
    sig = signature(text)
    if res["rc"] is not None and res["rc"] < 0:
        return "ZIG_CRASH", sig or f"signal {-res['rc']}"
    if sig and "FUZZ-DONE" not in res["out"]:
        return "ZIG_CRASH", sig
    if "FUZZ-DONE" not in res["out"]:
        # Factor-level error on Zig but not oracle
        first = next((l for l in (res["out"] + res["err"]).splitlines() if l.strip()), "no output")
        return "ZIG_CRASH", "factor-error: " + re.sub(r"0x[0-9a-fA-F]+", "0x?", first)[:160]
    if digest(res["out"]) != digest(oracle["out"]):
        a, b = digest(oracle["out"]), digest(res["out"])
        for x, y in zip(a, b):
            if x != y:
                for p, q in zip(x.split("|"), y.split("|")):
                    if p != q:
                        norm = lambda s: re.sub(r"\d+", "N", s)[:80]  # noqa: E731
                        return "MISMATCH", f"oracle={norm(p)} zig={norm(q)}"
                return "MISMATCH", "checkpoint field count"
        return "MISMATCH", "digest length"
    if sig:  # finished but printed something alarming (e.g. verifier warning)
        return "ZIG_CRASH", sig
    return "PASS", None


def save(findings, cls, seed, vm, prog_src, ops, flags, oracle, res, extended=False):
    d = os.path.join(findings, f"{cls}-{seed}-{vm}")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "prog.factor"), "w") as f:
        f.write(prog_src)
    with open(os.path.join(d, "ops.json"), "w") as f:
        json.dump(ops, f, indent=1)
    with open(os.path.join(d, "flags.txt"), "w") as f:
        f.write(" ".join(flags) + "\n" + vm + "\n" + ("extended\n" if extended else ""))
    for name, r in (("oracle", oracle), (vm, res)):
        if r is None:
            continue
        with open(os.path.join(d, f"{name}.stdout"), "w") as f:
            f.write(r["out"])
        with open(os.path.join(d, f"{name}.stderr"), "w") as f:
            f.write(r["err"])
    return d


def one(seed, args):
    rng = random.Random(seed * 7919 + 1)
    ops = gen.generate_ops(seed, extended=args.extended)
    src = gen.render(ops, True if args.extended else None)
    flags = pick_flags(rng) + shlex.split(args.zig_flags)
    ext = args.extended
    save_image = ext and args.save_image_every > 0 and seed % args.save_image_every == 0
    if save_image and shutil.disk_usage(TMPDIR).free < SAVE_MIN_FREE:
        print(f"[note] seed={seed}: <4GB free, skipping save-image phase", flush=True)
        save_image = False
    with (SAVE_SEM if save_image else contextlib.nullcontext()), \
            tempfile.TemporaryDirectory(dir=TMPDIR) as td:
        prog = os.path.join(td, f"fuzz{seed}.factor")
        with open(prog, "w") as f:
            f.write(src)
        img = (lambda name: os.path.join(td, name + ".image")) if save_image else (lambda name: None)
        oracle = run_vm(ORACLE, prog, args.timeout, img("oracle"))
        results = []
        if not oracle_ok(oracle):
            d = save(args.findings, "ORACLE_FAIL", seed, "oracle", src, ops, flags, oracle, None, ext)
            first = next((l for l in (oracle["out"] + oracle["err"]).splitlines() if l.strip()), "")
            return [dict(seed=seed, vm="oracle", cls="ORACLE_FAIL", sig=first[:160], dir=d, secs=oracle["secs"])]
        reload_ok = False
        if save_image:
            # The oracle must round-trip its own saved image, else the phase is a harness/generator issue.
            oreload = run_vm([ORACLE[0], "-i=" + img("oracle"), RELOAD_E], None, args.timeout)
            with contextlib.suppress(FileNotFoundError):
                os.remove(img("oracle"))
            reload_ok = oracle_ok(oreload) and digest(oreload["out"]) == digest(oracle["out"])
            if not reload_ok:
                d = save(args.findings, "ORACLE_FAIL", seed, "oracle-reload", src, ops, flags, oracle, oreload, ext)
                first = next((l for l in (oreload["out"] + oreload["err"]).splitlines() if l.strip()), "")
                results.append(dict(seed=seed, vm="oracle-reload", cls="ORACLE_FAIL", sig=first[:160], dir=d))
        for vm in args.vms:
            timeout = args.timeout * (2 if "debug" in vm else 1)
            res = run_vm(ZIG_VMS[vm] + flags, prog, timeout, img(vm))
            cls, sig = classify(oracle, res)
            rec = dict(seed=seed, vm=vm, cls=cls, sig=sig, flags=flags, secs=round(res["secs"], 2))
            if cls != "PASS":
                rec["dir"] = save(args.findings, cls, seed, vm, src, ops, flags, oracle, res, ext)
            results.append(rec)
            if save_image and reload_ok and cls == "PASS":
                # Reload the Zig VM's own image and re-print the digest; must match the oracle's run.
                rres = run_vm([ZIG_VMS[vm][0]] + flags + ["-i=" + img(vm), RELOAD_E], None, timeout)
                rcls, rsig = classify(oracle, rres)
                rrec = dict(seed=seed, vm=vm + "-reload", cls=rcls, sig=rsig, flags=flags, secs=round(rres["secs"], 2))
                if rcls != "PASS":
                    rrec["dir"] = save(args.findings, rcls, seed, vm + "-reload", src, ops, flags, oracle, rres, ext)
                results.append(rrec)
            if save_image:
                with contextlib.suppress(FileNotFoundError):
                    os.remove(img(vm))
        return results


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--count", type=int, default=100)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("--timeout", type=int, default=60)
    ap.add_argument("--zig-flags", default="")
    ap.add_argument("--vms", help="comma-separated subset of the --vm names to run (default: all)")
    ap.add_argument("--findings", default=os.path.join(HERE, "findings"))
    ap.add_argument("--results", default=os.path.join(HERE, "results.jsonl"))
    ap.add_argument("--extended", action="store_true", help="add gen.py's extended op families")
    ap.add_argument("--save-image-every", type=int, default=0,
                    help="with --extended: every Nth seed also saves an image and reloads it on each VM")
    add_vm_args(ap)
    args = ap.parse_args()
    configure(args)
    args.vms = [v for v in args.vms.split(",") if v] if args.vms else list(ZIG_VMS)
    for path in [ORACLE[0], ORACLE[1][3:]] + [ZIG_VMS[v][0] for v in args.vms]:
        if not os.path.exists(path):
            sys.exit(f"missing {path} (see misc/fuzz/README.md)")
    os.makedirs(args.findings, exist_ok=True)
    t0 = time.time()
    counts = collections.Counter()
    sigs = collections.defaultdict(list)
    with open(args.results, "a") as log, \
            cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(one, s, args): s for s in range(args.start, args.start + args.count)}
        for fut in cf.as_completed(futs):
            try:
                recs = fut.result()
            except Exception as e:  # harness bug
                recs = [dict(seed=futs[fut], vm="-", cls="HARNESS_ERROR", sig=repr(e))]
            for r in recs:
                log.write(json.dumps(r) + "\n")
                log.flush()
                counts[r["cls"]] += 1
                if r["cls"] != "PASS":
                    sigs[(r["cls"], r["sig"])].append((r["seed"], r["vm"]))
                    print(f"[{r['cls']}] seed={r['seed']} vm={r['vm']} {r['sig']}", flush=True)
    dt = time.time() - t0
    print(f"\n== {args.count} seeds in {dt:.0f}s ({args.count / dt * 60:.1f} seeds/min), vms={args.vms}, zig-flags={args.zig_flags!r}"
          f"{', extended' if args.extended else ''}"
          f"{f', save-image-every={args.save_image_every}' if args.save_image_every else ''}")
    for k, v in sorted(counts.items()):
        print(f"  {k:12s} {v}")
    if sigs:
        print("\n== unique signatures")
        for (cls, sig), where in sorted(sigs.items(), key=lambda kv: -len(kv[1])):
            print(f"  {cls:11s} x{len(where):<3d} {sig}   e.g. seed={where[0][0]} vm={where[0][1]}")
    return 1 if any(k != "PASS" for k in counts) else 0


if __name__ == "__main__":
    sys.exit(main())
