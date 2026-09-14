# Zig VM: format-float returns an empty string on Linux (glibc)

Found 2026-09-15 on Linux x86-64 (Ubuntu, glibc 2.39, Zig 0.16.0). Upstream
code links are pinned to
[`df18f5dc27`](https://github.com/factor/factor/commit/df18f5dc2734bfec84185166800b8b39d825a59b),
upstream `master` at the time.

## Summary

- On the Zig VM under glibc, the `(format-float)` primitive returns an
  empty byte-array for **every** call, so `sprintf` / `printf` with `%f` or
  `%e` (with or without precision/width) fail or produce the wrong result.
- The C++ VM on the same image is unaffected, and `number>string` is
  unaffected (it does not use this primitive).
- **Cause:** the Linux `LC_ALL_MASK` hard-coded in
  [`src/primitives/math.zig`](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/src/primitives/math.zig#L808-L814)
  is `0xFFF`. glibc rejects that mask with `EINVAL`, and the primitive treats
  the failure as an unknown locale.
- **Fix:** branch
  [`zig-vm-format-float-locale`](https://github.com/keiravillekode/factor-lang/tree/zig-vm-format-float-locale)
  (one commit off `master`).

## Reproduce

```factor
USING: formatting prettyprint ;
3.14159 "%.2f" sprintf .
```

| VM | Result |
|---|---|
| C++ | `"3.14"` |
| Zig (Debug or ReleaseSafe) | `Sequence index out of bounds` — `index 0`, `seq ""`, thrown from `fix-sign` |

More cases, the same on both Zig builds:

| Expression | C++ | Zig |
|---|---|---|
| `3.14159 "%f" sprintf` | `"3.141590"` | bounds error on `""` |
| `3.14159 "%e" sprintf` | `"3.141590e+00"` | bounds error on `""` |
| `3.14159 "%10.3f" sprintf` | `"     3.142"` | `"          "` (padding only) |
| `155000.0 B{ 0 } -1 3 B{ 69 0 } B{ 67 0 } (format-float)` | `B{ 49 46 53 53 69 43 48 53 }` (`1.55E+05`) | `B{ }` |
| `1.5 number>string` | `"1.5"` | `"1.5"` |

The `formatting` vocabulary's own tests show it too:

```sh
./factor -e='USING: io math.parser namespaces sequences tools.test ; "formatting" test test-failures get length number>string print'
```

| VM | `formatting` test failures |
|---|---|
| C++ | 0 |
| Zig, `master` | **41** |
| Zig, fix branch (Debug and ReleaseSafe) | 0 |

## Cause

[`src/primitives/math.zig`](https://github.com/factor/factor/blob/df18f5dc2734bfec84185166800b8b39d825a59b/src/primitives/math.zig#L808-L814)
on `master`:

```zig
// LC_ALL_MASK is libc-specific: BSD/macOS has 6 categories (bits 0..5), glibc
// has 12 (bits 0..11). Only used to validate the locale name, matching the way
// std::locale(name) throws on an unknown locale.
const lc_all_mask: c_int = switch (builtin.os.tag) {
    .linux => 0xFFF,
    else => 0x3F,
};
```

`primitive_format_float` calls `newlocale(lc_all_mask, locale, null)` and,
if that returns NULL, hands back an empty byte-array. That path is
deliberate: it mirrors the C++ VM, where `std::locale(name)` throws for an
unknown name, and `basis/formatting` tests it with the locale `"missing"`.

glibc numbers its categories 0..12, but `LC_ALL` is 6 and is not a
category, so glibc's `LC_ALL_MASK` is `0x1FBF` (bits 0..12 except 6). The
mask `0xFFF` sets bit 6 and misses bit 12, and glibc rejects it. A C
program on the same machine:

```
LC_ALL=6 LC_ALL_MASK=0x1fbf
mask=0xfff name="C" -> NULL (errno=Invalid argument)
mask=0xfff name="" -> NULL (errno=Invalid argument)
mask=0x1fbf name="C" -> ok (errno=Success)
mask=0x1fbf name="" -> ok (errno=Success)
```

So every locale, including `"C"`, is treated as unknown.

The mask was introduced in
[`f321fa720b`](https://github.com/factor/factor/commit/f321fa720bb5b1ba44182da3a0161723790ae2a7)
("zig vm: fix format-float", 2026-06-03). macOS is not affected: its
`LC_ALL_MASK` really is `0x3F`.

## Fix

Branch
[`zig-vm-format-float-locale`](https://github.com/keiravillekode/factor-lang/tree/zig-vm-format-float-locale),
commit `9638a36c10`, changes only `src/primitives/math.zig`:

```zig
const lc_all_mask: c_int = switch (builtin.os.tag) {
    .linux => if (builtin.abi.isMusl()) 0x7FFFFFFF else 0x1FBF,
    else => 0x3F,
};
```

`0x1FBF` is glibc's (and bionic's) `LC_ALL_MASK`; `0x7FFFFFFF` is musl's,
from Zig's bundled `generic-musl/locale.h`.

Checked on the fix branch, Linux x86-64 glibc:

- `formatting` tests: 0 failures on Debug and ReleaseSafe (41 before).
- All the cases in the tables above match the C++ VM byte for byte.
- An `x86_64-linux-musl` cross-compile builds. It was not run: that static
  binary stops at startup on an unrelated undefined-symbol error.

No new test was added: `basis/formatting/formatting-tests.factor` already
has about 25 float `sprintf` tests and the `(format-float)` tests that fail
without the fix.

## How it was found

Running the [Exercism Factor track](https://github.com/exercism/factor)'s
checks on the Zig VM. The example and exemplar solutions and the
accretive-exercise checks all pass, but 2 of 236 documentation examples
failed, both in
[`high-school-sweetheart`'s introduction](https://github.com/exercism/factor/blob/main/exercises/concept/high-school-sweetheart/.docs/introduction.md),
at `3.14159 "%.2f" sprintf`. With the fix, all 236 pass, as on the C++ VM.
The differential GC fuzzer ([fuzz-testing.md](fuzz-testing.md)) did not
catch it because its programs never format floats.
