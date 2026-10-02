# ADR-0145: The GUI is one file per concern; rio-gui.tcl is the entry

- **Status:** Accepted
- **Date:** 2026-10-02
- **Deciders:** jka

## Context

`rio-gui/rio-gui.tcl` was 14,103 lines and 689 procs in one file. The core's largest
file is 1,030. jka's instructions ask for code a human can read.

Tcl resolves a proc when it is called, so a proc can live in any file. Only top-level
code is bound to an order: the widgets, the menubar, the boot.

## Decision

- **`rio-gui.tcl` stays the entry.** It reaches the core, sources the parts, boots.
  Every installer and test still starts there.
- **A part is a concern:** its procs and the state they own. `rio-gui/<concern>.tcl`,
  flat, as in `rio-core/`.
- **Top-level code lives in three places only,** in this order: `build.tcl` (widgets),
  `menubar.tcl`, the entry's tail (boot).
- **Load order:** `state.tcl` first, `build.tcl` and `menubar.tcl` last. Between them,
  any order.

```
 rio-gui.tcl   args · spawn or connect the core
      │
      ├─ source  state … widgets     procs and their state
      ├─ source  build, menubar      top-level code: order matters
      │
      └─ boot    prefs · theme · session · first paint
```

- **Only the entry carries the D54 guard.** It sets the system encoding before a part
  is read.
- **The move changed no code.** Lines were cut by range, not retyped. A checker held
  old against new: the same 689 procs, the same top-level statements, the same order,
  bar the keymap tables, which now load before the widgets and read none of them.

## Alternatives considered

- **Move each pane's widgets into its concern file.** It changes the order widgets are
  created in, and with it stacking and focus traversal. Not earned yet.
- **Namespaces per concern.** A rename of 689 procs and every caller, tests included.
- **A `rio-gui/lib/` directory.** The core is flat; one way is enough.

## Consequences

- The largest GUI file is about 1,100 lines.
- `git blame` needs `-C` to see past the move.
- A new proc goes in its concern's file. New top-level code goes in `build.tcl`,
  `menubar.tcl` or the boot, never in a part.
