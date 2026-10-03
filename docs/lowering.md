# Lowering PowerShell to IL

Status: mechanism in use for the managed host; console lowering not started.
Findings dated 2026-10-02. The execution model this serves is in
[AGENTS.md](../AGENTS.md) ("PowerShell orchestrates, lowered code runs hot
paths").

## When to lower

Deterministic, fixed code is lowered at build time and ships in the APK: the
console core (parser, line store, wrap map, viewport, damage), the view host,
layout and navigation. User code (tile scripts, profiles, commands) stays
editable source and is the authority. When a user script's hot path is lowered
on the device at run time, as the execution model allows, the result is a
cache derived from that source and discarded when the source changes.

**Lower only what is finished.** Translating a moving target means translating
it twice, and the vectors only cover what the reference already does. The
console reference is not finished: on-screen text input (composition,
selection, deletion through an `InputConnection`) and the line store shared by
scrollback and the editor still have to be designed against real input. Two
small leaf types were translated as a pipeline trial (below); the rest waits.

## The pipeline

Everything is in `setup.ps1`; there is no C# compiler and no hand-written
opcode.

1. Describe each method as a typed `System.Linq.Expressions` tree from
   PowerShell, with the helpers `New-ClrConstant`, `New-ClrCall`,
   `New-ClrField`, `New-ClrAssign`, `New-ClrBlock` and `New-ClrLambda`.
2. Define types with `PersistedAssemblyBuilder` (`New-ManagedHostAssemblyBytes`
   is the worked example).
3. `Add-PersistedMethod` audits the tree with `Test-ExpressionGraph` and fails
   the build on any dynamic node, call-site reference, call-site constant, or
   constant IL cannot encode as a literal.
4. `Write-MicrosoftLambdaToMethodBuilder` runs System.Linq.Expressions' own
   `LambdaCompiler` with its IL generator pointed at the `MethodBuilder`, so
   the framework emits the IL.
5. `CreateType()`, `Save`, `Set-DeterministicMvid`: the same input gives the
   same bytes, which then go into the store like any other assembly.

PowerShell `class` methods are not a lowering target: the generated method
calls back into a script block (`ScriptBlockMemberMethodWrapper`,
`ClassOps.cs:98`, invoked at `:234`, PowerShell `149ab5cd`). The reference
`modules/Console.psm1` stays a reference; the lowered core is a separate typed
definition.

## Defect found: early returns emit invalid IL

**Status: fix identified and tested outside the build; not yet applied to
`setup.ps1`.**

`LambdaCompiler`'s constructor creates the label for a lambda's trailing
return (`AddReturnLabel`, called from `InitializeMethod`) and binds it to the
IL generator it has at that moment (`LambdaCompiler.cs:125-131`,
`LambdaCompiler.ControlFlow.cs:243-258`, runtime `ab194157`).
`Write-MicrosoftLambdaToMethodBuilder` replaces the compiler's generator only
after construction, so a jump to that label emits its `ret` into the discarded
generator. A method with an early `Return` then pushes its value and falls
through with a non-empty stack, and the JIT rejects it ("invalid IL").

Fix: after replacing the generator, clear `_labelInfo` and call
`AddReturnLabel` again. With it, the trial translations below compile, pass
the JIT, and match the reference. Acceptance when applied: the managed host
rebuilds byte-identical, and the IL check below reports nothing for any
persisted method.

## IL stack check

The audit in step 3 inspects the tree; nothing inspected the emitted IL. A
stack-depth checker closes that gap, in the spirit of the build's rule that
every emitter is decoded back by an independent decoder:

- Opcode bytes, operand kinds and stack behaviour are read from CoreCLR's
  `src/coreclr/inc/opcode.def` at the pinned runtime commit (291 opcodes),
  the same way the build reads ELF constants from `ELF.h`. Hand-written rules
  are limited to what that table cannot express, each with its source: operand
  sizes (ECMA-335 III.1.9), `calli` signature layout (ECMA-335 II.23.2) and
  runtime-async returns (`docs/design/specs/runtime-async.md:17,30`).
- It follows every branch and fails on underflow, on two paths reaching one
  instruction at different depths, on depth above the declared maximum, and
  on a `ret` with the wrong number of values.
- On the defect above it reports `IL_0052: depth 0 on one path, 1 on another`.
- Against 79,347 methods the JIT already accepts (System.Linq.Expressions,
  CoreLib, Regex, System.Management.Automation) it reports nothing after six
  rounds of correcting the checker itself (checked `[sbyte]` casts,
  generic-context token resolution, `calli`, multi-byte modifier tokens,
  runtime-async `ret`, and async-flagged methods that do not return a task).

It currently lives outside the repository; it becomes a build step after
`Add-PersistedMethod` when the fix above lands.

## Translation workflow

Translating a type into expression-tree build code is mechanical, so it can be
delegated, including to another model, provided acceptance is decided here:

1. **Prompt contract.** One function per type, built only from the helpers,
   with forbidden constructs listed (`Add-Type`, C#, `class`, `.Compile()`,
   dynamic expressions, call sites, `Invoke-Expression`, hand-written IL),
   tables copied literally between region markers, and no claim that it
   compiles.
2. **Harness, outside the build.** Load the helpers from `setup.ps1` by AST
   without running the build, compile the candidate, run the audit, save and
   load the assembly, force the JIT on every method, run the IL check, then
   compare against the reference: exhaustively where the domain allows, with
   edge and seeded random values otherwise.
3. **Feedback.** Failures go back verbatim as the next prompt.

Trial results with the fix applied:

| Type | Methods | Result |
| --- | --- | --- |
| `ConsoleWidth` | `InRanges`, `Of` | `Of` equals the reference for all 1,114,112 scalars |
| `ConsoleCells` (static members) | `BuildPalette`, `GetPalette`, `GetConsoleColorToPalette`, `Word0`, `ColorWord`, `Resolve` | Palette identical and cached; 2,919 colour/resolve cases and 3,753 `Word0` cases identical, including `int.MinValue` and out-of-range modes |

The second candidate first failed to parse: PowerShell ends a command's
arguments at a newline, so `(New-ClrAssign` followed by a line break called the
helper with no arguments. The prompt contract now states that rule.

Static fields holding tables are initialized on first use
(`Coalesce(field, Assign(field, NewArrayInit(...)))`), because the helper
compiles into a `MethodBuilder` and cannot emit a type initializer; such fields
are exposed through methods (`GetPalette`) rather than as fields.
