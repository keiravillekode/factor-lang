#!/usr/bin/env python3
"""Check the Factor code blocks in the symbolic algebra tutorial.

  FACTOR=/path/to/factor misc/symbolic-tutorial/check.py [tutorial.typ]

Every ```factor block in the Typst source is run as a program, with the
prelude below prepended. A line

    ! => text

states that the preceding code prints `text`; the block's expected output
is those lines in order, compared with what Factor prints. `!` starts a
Factor comment, so the blocks run exactly as they appear in the document.

Exits 0 when every block matches.
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_TUTORIAL = os.path.join(HERE, "tutorial.typ")

PRELUDE = """USING: arrays io kernel math math.functions math.symbolic
math.symbolic.calculus math.symbolic.compile math.symbolic.rules
namespaces prettyprint sequences ;
IN: tutorial

"""

BLOCK = re.compile(r"^```factor\n(.*?)^```", re.DOTALL | re.MULTILINE)
EXPECTED = re.compile(r"^\s*!\s*=>\s?(.*)$")


def blocks(text):
    for match in BLOCK.finditer(text):
        line = text[: match.start()].count("\n") + 1
        yield line, match.group(1)


def expected_output(block):
    return [
        m.group(1).rstrip()
        for m in (EXPECTED.match(line) for line in block.split("\n"))
        if m
    ]


def run(factor, source):
    with tempfile.TemporaryDirectory() as directory:
        path = os.path.join(directory, "block.factor")
        with open(path, "w") as file:
            file.write(source)
        result = subprocess.run(
            [factor, path], capture_output=True, timeout=300, stdin=subprocess.DEVNULL
        )
        return result.stdout.decode(errors="replace"), result.stderr.decode(errors="replace")


def check(factor, path):
    text = open(path).read()
    failures = 0
    total = 0
    for line, block in blocks(text):
        expected = expected_output(block)
        if not expected:
            continue
        total += 1
        out, err = run(factor, PRELUDE + block)
        actual = [l.rstrip() for l in out.split("\n") if l.strip()]
        if actual == expected:
            print(f"PASS {path}:{line}")
            continue
        failures += 1
        print(f"FAIL {path}:{line}")
        print("  expected:")
        for l in expected:
            print(f"    {l!r}")
        print("  actual:")
        for l in actual:
            print(f"    {l!r}")
        if err.strip():
            print("  stderr:")
            for l in err.split("\n")[:8]:
                print(f"    {l}")
    print(f"\n{total - failures}/{total} blocks pass")
    return failures


def main():
    factor = os.environ.get("FACTOR")
    if not factor:
        sys.exit("set FACTOR to the Factor executable")
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TUTORIAL
    return 1 if check(factor, path) else 0


if __name__ == "__main__":
    sys.exit(main())
