# Text editing

Status: design, 2026-10-02. Depends on the console core in
[console-reference.md](console-reference.md) and on on-screen text input,
which is not yet built.

Every view needs a way to edit text: the console's command line, tile and view
sources (a swipe away, see [views-and-tiles.md](views-and-tiles.md)), profiles,
and files. There is one editor core with several layouts, not one editor per
view.

## One core

Scrollback and an editor share the same structure:

- **Line store:** logical lines, each scalars plus style runs. Each line is
  its own array, so an edit touches one line, and append-only scrollback and
  mid-buffer editing use the same structure without a whole-text gap buffer.
- **Wrap map:** logical lines to visual rows at a width, cached per line and
  invalidated by width changes (pinch reflow already exercises this).
- **Viewport:** top visual row and height; maps a visual position back to line
  and column for the cursor and hit-testing.
- **Damage:** expressed as line ranges; it becomes row ranges only at the
  viewport.

The editor adds edits in the middle of a line, a cursor and selection in line
and column coordinates, and undo. The core is fixed, deterministic code and is
lowered once it is complete ([lowering.md](lowering.md)).

## Two layouts, one interface

The core never knows about pixels. Layout is a separate interface:

- **Cell layout:** a column is a cell, width from the pinned Unicode width
  tables, `x = column * cellWidth`. Exists today in the console.
- **Proportional layout:** positions from measured glyph advances
  (`Paint.getTextWidths` through JNI); wrapping and hit-testing use those
  advances. Not built.

The renderer is the hardware Canvas in both cases. The first editor is a
terminal-style editor on the cell layout; a proportional, Notepad-style editor
is a second layout over the same core, not a second editor. Any prompt or work
order for this code states the split, so cell assumptions do not leak into the
buffer.

## Behaviour and look

| Concern | Source |
| --- | --- |
| Buffer behaviour: edits, selection, undo, search and replace, line endings | Microsoft Edit (`microsoft/edit` at `c470ca59`), `crates/edit/src/buffer` (3,324 lines, MIT), ported with its repository and commit recorded |
| Command set, menus and settings | The author's earlier Notepad prototype: tabs, open, save, save all, find and replace (match case, wrap around), go to line, time and date, zoom, word wrap, status bar, font settings, session restore |
| Highlighting | SMA's tokenizer and parser for PowerShell; Edit's regular-expression highlighter is not carried over |
| Checking the buffer | Monaco's text buffer run on the PC as an oracle: the same edit sequences, the same resulting text and positions |

Most of Edit's roughly 28,000 lines are infrastructure that .NET and the console
already provide (its UI framework, ICU binding, Unicode tables, SIMD helpers, platform
layer, JSON), so the port is the buffer and the editor's behaviour, not the
program.

## Input

On-screen keyboards deliver composed text, selection changes and deletions
through an `InputConnection`, which needs the one fixed `NativeActivity`
subclass and a non-drawing input view on the roadmap. Until that exists the
console reads key events only. Composition and selection reach directly into
the line store, which is why the store is designed against real input before
it is lowered.
