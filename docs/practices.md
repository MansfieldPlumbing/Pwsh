# Working practices

These practices come from work on this repository and are kept because they
caught real defects. The rules they serve are in [AGENTS.md](../AGENTS.md).

## Evidence

- Name the source of every claim at an exact revision:
  `repo@commit:path:line`. Behaviour is traced to source, a specification, or
  a read-only probe; never guessed from symptoms.
- Keep the kinds of evidence apart: a specification says what should be true,
  an independent implementation (an oracle) catches a wrong reading of it, and
  a device receipt shows what survived the platform.
- Oracles check; they never produce. The TypeScript console oracle and
  Microsoft's own cmdlets on the PC (and, as planned, Monaco's text buffer and
  `WebClient`) are references that output is compared against, not code that
  ships.
- A receipt names the exact artifact (APK SHA-256), the device class, the
  workload and every check; a later build needs its own receipt.

## Tests

- Test what users do, not what the author imagined. Piping native command
  output line by line into the parsers revealed that a mandatory string
  parameter rejects the blank lines native output contains.
- Pin known limitations as test cases. A documented limitation with a case
  that asserts it turns any behaviour change into a visible failure instead of
  a silent one.
- Run every assertion. Chained `$pass = $pass -and (...)` stops evaluating at
  the first failure and hides the rest; count failures and exit with the
  count.
- Vectors are deterministic: generating them twice gives identical files.

## Optimization

- Choose a deterministic metric where one exists (operations issued over a
  fixed scenario suite) over wall-clock time; where only time exists, record
  the median and spread of repeated runs and treat anything inside the spread
  as no change.
- Freeze the baseline and guard behaviour mechanically: identical pixel hashes
  at every checkpoint, identical model state.
- One change per step, with its hypothesis and the source line it targets;
  keep it only if the metric improves and every guard holds; log every step,
  kept or reverted.
- Idle must cost nothing, and that is asserted: zero frames and zero
  PowerShell invocations while nothing changes.

## Delegating work to another model

- Give it a contract, not a wish: the exact output shape, the allowed
  building blocks, an explicit list of forbidden constructs, literal copying
  of data, and no claims about compiling or passing.
- Its own checks (a HUD, a lint) catch transcription mistakes only. Compile,
  audit, JIT, IL check and comparison against the reference run here.
- Return failures verbatim as the next prompt.
- Watch for invented structure: a work order proposed a command registration
  catalog where plain scripts on `PATH` already work; a request for
  damage-driven rendering came back as damage bookkeeping over a full repaint
  every frame, with a tile claiming otherwise.

## Design

- Prefer the platform's existing mechanism over a new layer: PowerShell
  already resolves a command name to a `.ps1` on `PATH`, so commands need no
  registry; the platform compositor is meant to run animation, so PowerShell
  needs no frame loop.
- Name things by mechanism, from the vocabulary of the code and platform:
  console host (`PSHost`), broker (a process that opens things for a
  sandboxed one and returns descriptors), Recovery. Avoid metaphors.
- Design the failure path with the feature: every failure leaves the user one
  step from a fix, and the way back never depends on the thing that failed.
- Lower only finished code; translate a moving target and it is translated
  twice.

## Working in the repository

- `setup.ps1` fails if anything outside `build/` changes during a run. Do not
  edit tracked files while a build is running.
- Back up a file before overwriting it, outside the repository.
- Device identifiers are personal data: mask serials in all output, read only
  the app's own data, and never name a personal device in repository files.
