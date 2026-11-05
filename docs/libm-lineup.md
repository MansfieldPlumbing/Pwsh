# Math library lineup: CoreCLR on the UCRT and on bionic

Status: measured 2026-11-05 on one build of the runtime on both sides; a
correctly rounded replacement is planned, starting with `Sin`, and is not
built. The direction this serves is removing the C runtime underneath
PowerShell: CoreCLR's `[Math]` calls end in the platform's libm, so a
replacement has to exist before the C runtime can go.

Every claim below is TRUE, FALSE or UNKNOWN as decided by the measurement
named with it. Hypotheses are labelled as such and decide nothing.

## The finding

Neither platform's libm is correctly rounded everywhere. Where the PC and
the phone give different finite results, the exact answer is with Windows in
203 cases and with Android in 134. In 5 further cases they agree and both are
wrong. A single correctly rounded implementation would beat both platforms
and give the same last bit on each of them.

## What ran

| | PC | Phone |
| --- | --- | --- |
| Runtime | .NET 11 RC 1, CoreCLR 11.0.26.42628, commit `3551975b` | the same |
| Host | sidecar pwsh 7.7.0-preview.5 (`C:\bin\pwsh-7.7.0-preview.5`, zip SHA-256 `BA727D18…`) | this repository's app, SMA 7.7.0-preview.4, APK SHA-256 `236FB086…24A88` |
| Machine | x64 (Xeon W-2145), Windows 11 26100 | arm64, OnePlus 11 (SM8550), Android 16 |
| libm | UCRT, linked from `coreclr.dll` | bionic, linked from `libcoreclr.so` |

The phone's `libcoreclr.so`, `libclrjit.so` and `libSystem.Native.so` are
byte-identical to the published RC 1 Android runtime pack, so the managed
side of the comparison is the same code. The only thing that differs is the
platform underneath.

The same script (SHA-256 `2D95DBC7…F5029`) ran on both: on the phone as
`Profile.ps1` through `tools/Invoke-DeviceScript.ps1`, and on the PC with
the sidecar pwsh. It evaluates 17 unary `[Math]` functions plus `Pow`,
`Atan2` and the `R` round-trip format, and writes `function|input bits|output
bits` lines. Its inputs are deterministic: special values (zeros, infinities,
NaN, subnormals, exact constants such as 0.5, 2, π and 710) plus values from a
64-bit linear congruential generator computed in `BigInteger` modulo 2^64
(seed 11400714819323198485, multiplier 6364136223846793005, increment
1442695040888963407). Generating them twice gives the same file.

## Results

8,358 cases; 6,562 are bit-identical across the two platforms.

| Function | Cases | Identical | NaN sign only | Value differs | Exact answer with Windows | with Android |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Acos | 418 | 198 | 220 | 0 | | |
| Asin | 418 | 197 | 220 | 1 | 1 | 0 |
| Atan | 418 | 418 | 0 | 0 | | |
| Atan2 | 417 | 349 | 0 | 68 | 68 | 0 |
| Cbrt | 418 | 284 | 0 | 134 | 16 | 118 |
| Cos | 418 | 416 | 2 | 0 | | |
| Cosh | 418 | 408 | 0 | 10 | 8 | 2 |
| Exp | 418 | 417 | 0 | 1 | 1 | 0 |
| FormatR | 418 | 418 | 0 | 0 | | |
| Log, Log10, Log2 | 418 each | 215 each | 203 each | 0 | | |
| Pow | 417 | 216 | 201 | 0 | | |
| Round | 418 | 418 | 0 | 0 | | |
| Sin | 418 | 406 | 2 | 10 | 3 | 7 |
| Sinh | 418 | 375 | 0 | 43 | 41 | 2 |
| Sqrt | 418 | 215 | 203 | 0 | | |
| Tan | 418 | 407 | 2 | 9 | 4 | 5 |
| Tanh | 418 | 357 | 0 | 61 | 61 | 0 |
| Truncate | 418 | 418 | 0 | 0 | | |

Every value difference is 1 ulp except one `Tanh` case at 2 ulp.

## How the exact answer is decided

Three bearings, each independent of the platforms being judged:

1. **Exact reference.** Each function is evaluated in `BigInteger` fixed
   point at 300 bits (π by Machin's formula, ln 2 by series, and exp, sin,
   cos, atan and cbrt with argument reduction), and the result is rounded to
   the nearest double. Every verdict was recomputed at 500 bits; none changed.
2. **Exact cube test for `Cbrt`.** It needs no series at all: for two
   adjacent candidate doubles, the midpoint m between them is exact, and m³ is
   compared with the input exactly in `BigInteger`. The correct candidate is
   the one on the same side of m as the true cube root. It gives Android 118,
   Windows 16, and agrees with the reference in all 134 cases.
3. **Self-check on agreement.** On 394 cases where both platforms agree, the
   reference put the shared result within half an ulp in 382. A recheck of the
   12 others at 300 and 500 bits found 5 genuine (below). The remaining 7 have
   outputs too small for 300-bit fixed point to resolve, and the checker
   could not judge them: a limit of the instrument, not a verdict. A
   relative-precision reference would close that gap.

## Rare percepts

The first bank of differences (NaN encodings, 1-ulp splits) is expected.
These are not:

- **All NaN differences are one bit.** All 1,459 are `FFF8000000000000`
  on x64 against `7FF8000000000000` on arm64: the same quiet NaN with the
  sign bit set or clear. This matches the default NaN each ISA documents (the
  x87/SSE "indefinite" has the sign set; ARM's default NaN has it clear).
  Hypothesis, not yet traced to an instruction.
- **Famous constants are wrong.** The UCRT gets `cbrt(2)`, `cbrt(0.5)`,
  `cbrt(π)` and `cbrt(-745)` wrong by 1 ulp: it gives `cbrt(2)` as
  `0x3FF428A2F98D728A` where the correctly rounded result is `…728B`. Bionic
  gets `sinh(2)`, `sinh(π)`, `sinh(710)` and `cosh(710)` wrong.
- **`Sin` and `Tan` disagree on the same inputs.** 3 inputs are disputed in
  both against 0.22 expected by chance (13.9×): −49.547035757636884,
  2644.4587236879515 and 695319.9977882551. On each, whichever platform is
  right for `Sin` is wrong for `Tan`. Hypothesis: the two libraries reduce the
  argument differently, and both functions inherit the difference.
- **`Sinh` and `Cosh` at 710 give the same pair of bits.** Both platforms
  give `sinh(710)` and `cosh(710)` identical bits, and they differ from each
  other identically (`…07F9` against `…07FA`). This is consistent with both
  using exp(x)/2 near overflow, where e^−x no longer matters. Hypothesis.
- **The only 2-ulp case** is `tanh(0.46885322087761505)`. The same input is
  also a `Sinh` dispute, and Windows is right on both.
- **Both wrong together, all in `Sin`.** The five agreed misses are
  sin(−50249637.23855045), sin(58.80164503177653),
  sin(−50.939600584947634), sin(−3420438.16424402) and
  sin(−91.81087528895593). Each is 0.526 to 0.567 ulp off, and the results
  were the same at 300 and 500 bits.
- **musl is not an independent bearing against bionic.** Bionic's libm is
  FreeBSD's msun. Its `k_sin.c`, `k_cos.c`, `s_cbrt.c` and `k_tan.c` share
  every floating-point constant with musl 1.2.5's `__sin.c`, `__cos.c`,
  `cbrt.c` and `__tan.c` (8/8, 9/9, 11/11, 22/22), and `e_rem_pio2.c` shares 7
  of them. Both carry Sun's 1993 fdlibm. A third bearing for these functions
  has to come from a different lineage: glibc, CORE-MATH, or the UCRT itself.

## Plan: a correctly rounded `Sin` first

`Sin` comes first because it has the cases both platforms get wrong, the
`Tan` coupling suggests the fault is in argument reduction, and correctly
rounded double `sin` has published prior art: the CORE-MATH project, read as
a bearing, not taken as a dependency.

1. Written in PowerShell and lowered by PSC; no C, and no call into the
   platform's libm.
2. Argument reduction exact for every double: a Cody–Waite reduction for
   small inputs, and a Payne–Hanek reduction against enough bits of 2/π for
   large ones (the lineup's agreed misses include |x| above 5·10⁷).
3. A fast path in double-double, with a rounding test. Where the test cannot
   decide, a slower exact path (the `BigInteger` reference) decides.
4. Judged by the same exact reference, as a third participant in the same
   lineup on the PC and on the phone. Success is: the replacement is
   correctly rounded in every case, including the five agreed misses and the
   ten disputes, and its bits are identical on both platforms.

## Limits

- One build (RC 1), one PC and one phone. Another CPU or a later runtime
  needs its own run.
- 418 inputs per function find disagreements; they do not prove agreement
  anywhere else.
- The comparison and the reference ran as session commands, so the data
  files are not in this repository. The inputs above regenerate exactly; the
  instrument that compares and judges belongs in one script, not yet written.
