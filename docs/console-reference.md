# Console reference implementation: build contract

This is a build contract for an implementation made outside this repository
(for example by AI Studio). Build exactly what it specifies. Where it is
silent, do not invent: leave the feature out and list it under "Not done" in
the deliverable's `REPORT.md`.

## Role

A TypeScript reference implementation of the Pwsh console core. It is used in
two ways and never shipped in the APK:

1. As an oracle: its conformance vectors and outputs check the PowerShell and
   emitted-IL implementations on Android devices.
2. As a web client for the contract stream (`docs/shell.md`): it renders frames
   read from the frame ring.

## Sources: clone and study exactly these

Study only these sources. Do not use other terminal emulators, libraries or
blog posts as references. If a download's SHA-256 differs from the value
below, stop and report it; do not substitute another version.

| Source | Revision | What to take from it |
| --- | --- | --- |
| `https://github.com/MansfieldPlumbing/Pwsh` | the commit named in the request | `docs/shell.md` (event bus, frame ring, consumers, cell format intent), `docs/host.md`, this file, `modules/AndroidCanvas.psm1` (the drawing primitives a renderer maps to: `Clear-Canvas`, `Add-CanvasRect`, `Add-CanvasText`), and in `setup.ps1` the functions `Get-CanvasCells` and `Render-Canvas` (cell grid; emitting output only where the format changes) and `Invoke-SetupInterface` (blocking event queue, drain then render once) |
| `https://github.com/PowerShell/PowerShell` | tag `v7.7.0-preview.4`, commit `1481b98f0079f979f658e49a7281024cc754049b` | the host contract: `src/System.Management.Automation/engine/hostifaces/MshHostUserInterface.cs` and `MshHostRawUserInterface.cs`; ConsoleHost's behavior: `src/Microsoft.PowerShell.ConsoleHost/host/msh/ConsoleHostUserInterface.cs`, `ConsoleHostRawUserInterface.cs`, `ConsoleHostUserInterfaceProgress.cs` |
| `https://www.unicode.org/Public/16.0.0/ucd/EastAsianWidth.txt` | SHA-256 `43ADC76C0686A42CB370764EB8CFE2B2A45B10B855E5572A2DB4A0EECCE15D5B` | cell widths |
| `https://www.unicode.org/Public/16.0.0/ucd/UnicodeData.txt` | SHA-256 `FF58E5823BD095166564A006E47D111130813DCF8BF234EF79FA51A870EDB48F` | general categories for zero-width scalars |
| `https://vt100.net/emu/dec_ansi_parser` | SHA-256 `72DB5905EBD81BB4F3DA420DB66DB390BFA6693704BC5E24AEC74290D2CE691D` | the escape-sequence parser state machine |
| `https://invisible-island.net/xterm/ctlseqs/ctlseqs.txt` | XTerm Patch #411, SHA-256 `364C1C1987C85B1C1135E57A93E9008054F46D09A338DE8DCC66EA9A7C613709` | only "CSI Pm m" (Character Attributes, SGR) |
| `terminal-best-example` (uploaded by the owner) | as uploaded | prior art only: `src/System.ConsoleEngine.ts` (transcript tagged by stream, line editor, history) and `src/components/Terminal.App.Console.tsx` (repaint only changed cells). Do not copy anything else from it. |

Generated tables (widths, categories) are produced by a script in the
deliverable from the pinned Unicode files, and the script records their
SHA-256. Tables are never typed by hand.

## Rules

- TypeScript `strict`, ES2022 modules. `devDependencies` exactly:
  `typescript` `5.8.2`, `vite` `6.2.3`, `tsx` `4.21.0`. No `dependencies`.
- Tests use `node:test` and `node:assert`, run with `tsx`.
- `src/core/` imports nothing from the DOM, React or Node. No timers in
  `src/core/`: no `setTimeout`, `setInterval`, `requestAnimationFrame`,
  `Date.now`, `performance.now`.
- `src/view/` may use the DOM and Canvas 2D. It draws only in response to a
  ring commit or an input event, at most once per commit, and never in a loop.
- Iterate strings by Unicode scalar (`for...of`, `codePointAt`), never by
  UTF-16 unit.
- No React, Tailwind, CSS frameworks, xterm.js or any terminal library.

## Data formats

### Cell: three `uint32` words, 12 bytes, little-endian

| Word | Bits | Meaning |
| --- | --- | --- |
| 0 | 0-20 | Unicode scalar value; 0 means an empty cell (drawn as a space) |
| 0 | 21-22 | width: 1 normal, 2 wide (first cell), 0 continuation of a wide cell |
| 0 | 23 | bold |
| 0 | 24 | italic |
| 0 | 25 | underline |
| 0 | 26 | inverse |
| 0 | 27 | strike |
| 0 | 28 | dim |
| 0 | 29-31 | zero |
| 1 | 0-23 | foreground: `0xRRGGBB`, or a palette index 0-255 in bits 0-7 |
| 1 | 24-25 | foreground mode: 0 default, 1 palette index, 2 RGB |
| 1 | 26-31 | zero |
| 2 | 0-25 | background, same layout as word 1 |
| 2 | 26-31 | zero |

The continuation cell of a wide character has scalar 0, width 0, and the same
colors and attributes as its first cell.

### Palette

Default foreground `0xCCCCCC`, default background `0x0C0C0C`. Indexes 0-15
(ANSI order): `0C0C0C C50F1F 13A10E C19C00 0037DA 881798 3A96DD CCCCCC 767676
E74856 16C60C F9F1A5 3B78FF B4009E 61D6D6 F2F2F2`. Indexes 16-231: `16 + 36r +
6g + b` for r, g, b in 0-5, each level mapping to `0, 95, 135, 175, 215, 255`.
Indexes 232-255: gray `8 + 10k` for k in 0-23.

`System.ConsoleColor` maps to palette indexes as: Black 0, DarkBlue 4,
DarkGreen 2, DarkCyan 6, DarkRed 1, DarkMagenta 5, DarkYellow 3, Gray 7,
DarkGray 8, Blue 12, Green 10, Cyan 14, Red 9, Magenta 13, Yellow 11, White 15.

### Frame ring

One `ArrayBuffer` (a `SharedArrayBuffer` when available) holding three slots.
Each slot is a 64-byte header followed by `cols * rows * 12` bytes of cells in
row-major order. Header, little-endian:

| Offset | Type | Field |
| --- | --- | --- |
| 0 | u32 | magic `0x52465750` (ASCII `PWFR`) |
| 4 | u16 | format version, 1 |
| 6 | u16 | header size, 64 |
| 8 | u64 | sequence; 0 means the slot was never committed |
| 16 | u32 | columns |
| 20 | u32 | rows |
| 24 | u32 | cursor column |
| 28 | u32 | cursor row |
| 32 | u32 | flags: bit 0 cursor visible |
| 36 | u32 | cell format, 1 |
| 40-63 | | zero |

The writer writes the slot that is neither the newest committed slot nor the
slot most recently acquired by a reader, then sets its sequence to the
previous maximum plus one; the sequence is written last. `acquireLatest()`
returns the slot with the highest sequence. The writer never waits.

## Modules and exports

```ts
// src/core/cell.ts
export const CELL_WORDS = 3;
export interface CellStyle { fg: number; fgMode: 0 | 1 | 2; bg: number; bgMode: 0 | 1 | 2; attrs: number } // attrs: bits 23-28 of word 0, shifted down by 23
export function packCell(scalar: number, width: 0 | 1 | 2, style: CellStyle): [number, number, number];
export function unpackCell(words: Uint32Array, index: number): { scalar: number; width: 0 | 1 | 2; style: CellStyle };
export function resolveColor(value: number, mode: 0 | 1 | 2, isForeground: boolean): number; // to 0xRRGGBB using the palette above

// src/core/width.ts (tables generated by scripts/generate-unicode.ts)
export function scalarWidth(scalar: number): 0 | 1 | 2; // 2 for East_Asian_Width W or F; 0 for categories Mn, Me, Cf and for U+200B; else 1

// src/core/parser.ts: the vt100.net state machine, all states and transitions
export type ParserAction =
  | { kind: 'print'; scalar: number }
  | { kind: 'execute'; code: number }
  | { kind: 'csi'; params: number[]; intermediates: string; final: string; private: string }
  | { kind: 'esc'; intermediates: string; final: string }
  | { kind: 'osc'; data: string };
export class Parser { feed(text: string, emit: (action: ParserAction) => void): void }

// src/core/sgr.ts: only CSI ... m, semicolon-separated parameters
export function applySgr(style: CellStyle, params: number[]): CellStyle;

// src/core/console.ts
export type Stream = 'Output' | 'Error' | 'Warning' | 'Verbose' | 'Debug' | 'Information';
export class ConsoleModel {
  constructor(cols: number, rows: number);
  write(stream: Stream, text: string, fg?: number, bg?: number): void;      // fg/bg: ConsoleColor values 0-15
  writeProgress(activityId: number, activity: string, status: string, percent: number, completed: boolean): void;
  setPrompt(prompt: string): void;
  editorInsert(text: string): void;
  editorBackspace(): void;
  editorDelete(): void;
  editorMove(delta: number): void;
  editorHome(): void;
  editorEnd(): void;
  editorSetComposition(text: string): void;
  historyUp(): void;
  historyDown(): void;
  submit(): string;                  // returns the command, records it in history, clears the editor
  scroll(deltaRows: number): void;
  resize(cols: number, rows: number): void;
  compose(target: Uint32Array): { cursorCol: number; cursorRow: number; cursorVisible: boolean };
}

// src/core/ring.ts
export class FrameRing {
  constructor(buffer: ArrayBuffer | SharedArrayBuffer, cols: number, rows: number);
  static byteLength(cols: number, rows: number): number;
  beginWrite(): { cells: Uint32Array; slot: number };
  commit(slot: number, cursorCol: number, cursorRow: number, cursorVisible: boolean): bigint; // returns the sequence
  acquireLatest(): { sequence: bigint; cols: number; rows: number; cells: Uint32Array; cursorCol: number; cursorRow: number; cursorVisible: boolean } | null;
}

// src/core/diff.ts
export type DrawOp =
  | { kind: 'fill'; row: number; col: number; count: number; bg: number }                              // bg as 0xRRGGBB
  | { kind: 'text'; row: number; col: number; text: string; cells: number; fg: number; attrs: number }; // fg as 0xRRGGBB
export function diffFrames(previous: Uint32Array | null, next: Uint32Array, cols: number, rows: number): DrawOp[];
```

## Behavior

### Parser and SGR

- Implement every state and transition of the vt100.net parser. Its actions
  become `ParserAction` values.
- The console applies only CSI with final `m` and no private marker or
  intermediates, through `applySgr`. Every other CSI, ESC, OSC, DCS, SOS, PM
  and APC sequence is consumed and has no effect.
- SGR parameters: 0 reset; 1 bold; 2 dim; 3 italic; 4 underline; 7 inverse; 9
  strike; 22 not bold and not dim; 23 not italic; 24 not underline; 27 not
  inverse; 29 not strike; 30-37 and 90-97 foreground index 0-7 and 8-15; 39
  default foreground; 40-47 and 100-107 background index 0-7 and 8-15; 49
  default background; `38;5;n` and `48;5;n` palette index n; `38;2;r;g;b` and
  `48;2;r;g;b` RGB. An empty parameter list means 0. Unknown parameters are
  ignored. A malformed extended color ignores only that color.
- C0 controls: LF ends the logical line; CR followed by LF is one line end; a
  lone CR moves the column to 0 of the current logical line, and later
  characters overwrite; TAB advances to the next multiple of 8 columns,
  filling with spaces; BS moves back one column without erasing, not past
  column 0; every other C0 control is ignored.

### Console model

- The transcript is a list of entries, each with a stream, logical lines of
  styled cells, and a version number that changes when the entry changes.
- Stream colors: the defaults of ConsoleHost's `ErrorForegroundColor`,
  `ErrorBackgroundColor`, `WarningForegroundColor`, `WarningBackgroundColor`,
  `VerboseForegroundColor`, `VerboseBackgroundColor`, `DebugForegroundColor`,
  `DebugBackgroundColor`, taken from `ConsoleHostUserInterface.cs` at the pinned
  commit (`ConsoleHostUserInterface.cs` from line 1409). Put the file and line
  in a comment. A default written as `Console.BackgroundColor` or
  `Console.ForegroundColor` means the default color (mode 0). `Output` and `Information`
  use the default colors. Explicit `fg`/`bg` override the stream colors. SGR
  inside the text overrides both, from its position to the end of that
  `write` call.
- Progress: at most one progress row per activity, shown directly above the
  editor rows, formatted as `activity: status [percent%]` in the colors of
  ConsoleHost's `ProgressForegroundColor` and `ProgressBackgroundColor`
  defaults; `completed` removes it.
- Wrapping: a logical line wraps at `cols`. A wide character that would start
  in the last column moves to the next row, leaving the last column empty.
  Wrapped rows are cached per entry, keyed by entry version and `cols`; a
  resize re-wraps from the logical lines.
- Editor: the prompt, a space, the editor text, then the composition text
  (inverse attribute) at the caret. It wraps like output. Caret moves by
  scalar. History: up and down walk submitted commands, and the text being
  edited is kept and restored after the newest entry.
- Viewport: pinned to the bottom until `scroll` moves it up; scrolling back
  to the bottom pins it again; any editor change pins it.
- The cursor is at the caret's cell, visible when the viewport shows it. No
  blink.

### Diff

`diffFrames(null, ...)` returns a full frame. Otherwise it compares cells and,
on each row with changes, covers every changed cell. In each covered stretch,
consecutive cells with equal style merge: one `fill` for their background,
then one `text` for their characters (empty cells become spaces; continuation
cells add no text but count in `cells`). Inverse swaps resolved foreground and
background. Ops are ordered by row, then column.

## View (`src/view/`)

- A page with one `<canvas>` and a visually hidden `<input>` for keyboard and
  IME text. Font: monospace; cell width from `measureText('M')`, cell height
  `ceil(fontSize * 1.25)`; the canvas is sized in device pixels.
- Keys: printable input and `compositionend` call `editorInsert`;
  `compositionupdate` calls `editorSetComposition`; Backspace, Delete, arrows,
  Home, End, Enter (`submit`, then echo the command as an `Output` entry with
  the prompt) and PageUp/PageDown (`scroll`).
- Every state change composes into the ring and commits. The renderer acquires
  the latest slot, diffs it against the last frame it drew, draws the ops
  (`fill` as a rectangle, `text` with `fillText` at cell positions), and keeps
  that frame.
- A demo panel with buttons that write sample output for every stream, SGR
  16, 256 and RGB colors, wide characters, emoji, a progress sequence, and a
  resize.

## Conformance vectors (`vectors/*.json`)

Each file:

```json
{ "name": "sgr-truecolor", "cols": 20, "rows": 4,
  "steps": [ { "op": "write", "stream": "Output", "text": "\u001b[38;2;1;2;3mA" } ],
  "expect": { "cells": [[0, 0, 65, 1, 0, 2, 66051, 0, 0]],
              "cursor": [0, 1, true] } }
```

`steps` use the `ConsoleModel` method names as `op`, with their arguments as
named fields. `expect.cells` lists the cells to check as `[row, col, scalar,
width, attrs, fgMode, fg, bgMode, bg]`, and `expect.cursor` is `[col, row,
visible]`. Provide at least these vectors, one file each: plain text; LF;
CRLF; lone CR overwrite; TAB; BS; every SGR attribute on and off; SGR 30-37,
90-97, 40-47 and 100-107; 38;5 and 48;5 at 0, 15, 16, 231, 232 and 255;
38;2 and 48;2; malformed 38;2; reset; an ignored CSI (cursor movement); an
ignored OSC title; wrapping at `cols`; a wide character at the last column; a
zero-width scalar; an emoji above U+FFFF; resize re-wrap; each stream's
colors; explicit `fg`/`bg`; progress show, update and complete; editor insert,
caret move and backspace across an emoji; composition; history up, down and
restore; scroll up and re-pin; and `diffFrames` on one changed cell and on a
style run.

## Deliverable

```
package.json  tsconfig.json  vite.config.ts  index.html  REPORT.md
scripts/generate-unicode.ts
src/core/{cell,width,parser,sgr,console,ring,diff}.ts
src/core/generated/{width,categories}.ts
src/view/main.ts
test/*.test.ts
vectors/*.json
```

Acceptance, all of which must pass and be shown in `REPORT.md`:

1. `npx tsc --noEmit` with no errors.
2. `npx tsx --test test/*.test.ts`: every vector and unit test passes.
3. `grep -rE "setTimeout|setInterval|requestAnimationFrame|Date\.now|performance\.now|document|window" src/core` finds nothing.
4. `scripts/generate-unicode.ts` verifies both Unicode files against the
   SHA-256 values above before generating.
5. `REPORT.md` lists each source file studied with its revision, each
   requirement of this document with the file and test that meets it, and
   anything not done.
