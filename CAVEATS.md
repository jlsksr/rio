# rio — caveats & limitations

A running list of rio's **rough edges worth remembering** — split into two kinds:

1. **Cross-platform behaviour differences** — the *same* rio code behaving differently on
   one OS / window manager / toolkit than on another. These are usually traits of Tk or the
   surrounding environment rather than bugs in rio's own code.
2. **Behavioural limitations** — deliberate simplifications in rio's *own* design that hold
   the same on every platform: a documented trade-off where a fuller behaviour was
   consciously deferred, not a bug.

Each entry records the **symptom**, the **cause**, **where it's fine**, rio's current
**mitigation**, and any **planned** work (with a pointer to [ROADMAP.md](ROADMAP.md) /
[AGENTS.md](AGENTS.md)). When you hit a new "works here, not there" quirk, or notice a
design limit that surprises, append it to the matching section.

---

## Cross-platform behaviour differences

### Over-tall menus close on hover (X11)

- **Symptom.** A menu posted **taller than the screen space below it** can **unpost the
  moment the pointer hovers an item in the middle** of the list. Seen on X11 under xfwm4;
  the View menu was the one that reached this size.
- **Cause.** Tk's Unix menu widget tries to reposition a too-tall menu to fit and then
  scroll it (it has native scroll arrows in the C widget), but that reposition/scroll
  machinery interacts badly with the pointer grab on some window managers. It is a
  long-standing rough edge in Tk's X11 menu code, not a knob we can switch to "reliable".
- **Where it's fine.** **Windows and macOS.** There Tk renders the menubar with the
  **native OS menu**, and the OS scrolls tall menus correctly — so this class of glitch
  never appears off X11. (That is exactly why it is X11-only.)
- **Mitigation in rio.** Keep menus **short enough to fit** by grouping less-used items
  into submenus (AGENTS.md **D64** — the View menu dropped from ~30 rows to ~18). We do
  **not** patch Tk's menu grab/post/scroll internals: an earlier attempt to (AGENTS.md
  **D59**) caused its own intermittent click misfires and was reverted.
- **At scale (planned).** Grouping bounds the *fixed* menus, but one menu is still
  **data-driven and unbounded** — the **Theme** cascade (grows with installed themes, D39) —
  and it can still outgrow the screen. The durable fix is to render it as rio's scrollable
  `rl_*` rich-list picker (the same component the Files / Git / Extensions panes use), which
  has a bounded height and a scrollbar and never posts a screen-tall menu. Tracked under
  *Menu overflow at scale* in [ROADMAP.md](ROADMAP.md). (The other unbounded menu, the
  per-buffer **Tabs** cascade, was already retired this way in **D74** — it became the
  bounded **View ▸ Switch to Tab…** dialog.)

### A killed command's exit code differs on Windows (there are no signals)

- **Symptom.** When the agent's `run_command` tool **times out** and rio kills the child, the
  exit code in the result is **-1 on unix but 1 on Windows**. The same happens for any other
  killed child.
- **Cause.** `rio::exec::_kill` has no portable primitive to reach for (Tcl 8.6), so it shells
  out: `kill -TERM` on unix, `taskkill /F /T` on Windows. Unix then reports the death as a
  **signal** — Tcl surfaces `CHILDKILLED`, which rio maps to -1. Windows **has no signals**:
  a force-terminated process simply *exits*, with code 1, which arrives as an ordinary
  `CHILDSTATUS`. There is no Windows exit code that means "was killed".
- **Where it's fine.** **Everywhere, in practice** — because nothing reads that number to
  decide what happened. The `timedout` flag carries the meaning, and
  `rio::agent::tools::format_exec` checks it *before* it ever looks at the exit code, so a
  timed-out command is reported to the model as a timeout on both platforms.
- **Mitigation in rio.** Treat `timedout` as the signal and the exit code as data. The test
  (`rio-core/tests/exec.test`, `exec-start-timeout`) asserts `timedout` and *non-zero*
  rather than pinning a platform-specific number.
- **Planned.** Nothing. Windows cannot distinguish "killed" from "exited 1", so this is a
  property of the platform, not a gap to close.

---

## Behavioural limitations

### Drag-to-open needs the optional tkdnd extension, and a local core

- **Symptom.** Dragging a file from the OS file manager onto the rio-gui window does
  **nothing** — no tab opens. Or: it works for a locally-launched rio but not when the GUI is
  attached to a remote core.
- **Cause.** Two separate reasons. (1) **Plain Tk cannot receive an OS file drop at all** — that
  capability lives only in the external **tkdnd** extension (AGENTS.md **D86**), which rio loads
  *optionally* (`catch {package require tkdnd}`): where it isn't installed, there is simply
  nothing listening for the drop. (2) A dropped path is a path on the **GUI's own machine**, but
  the *core* performs the file open; with a **remote** core that path is meaningless, so rio
  registers drop targets only for a **local** core — a remote drop is refused with the native
  "no-drop" cursor.
- **Where it's fine.** A **local** rio with **tkdnd installed** (the Magicsplat Tcl/Tk
  distribution bundles it on Windows; Linux/BSD install the `tkdnd` package). Drag one or several
  files — or a folder — onto the editor, a dock, or the tab strip and they open.
- **Mitigation in rio.** The feature degrades cleanly: without tkdnd rio-gui runs exactly as
  before, and **every other way to open a file** (File ▸ Open…, the file pane, `argv`) is
  unaffected. Install tkdnd to turn drag-to-open on — see [INSTALL.md](INSTALL.md) /
  [WINDOWS.md](WINDOWS.md).
- **Planned.** Uploading a dropped *local* file's bytes to a **remote** core (so drag-to-open
  works over the wire too) is a deliberate follow-up, noted out-of-scope in AGENTS.md **D86**,
  not yet scheduled.

### Two no-project windows share one anonymous session

- **Symptom.** Run **two rio instances that both have no folder open** (the loose "daily
  workspace" case) and their open-tab sets **overwrite each other**: whichever saves last
  wins, so a later launch resumes only one of the two sets rather than both.
- **Cause.** The resume session for the **no-project** state is a *single* file
  (`sessions/anonymous.json`, AGENTS.md **D72**): with no project root there is nothing to
  key it by, so every no-project instance shares the one file, and `session_save` (fired on
  each tab change and on quit) rewrites it.
- **Where it's fine.** The intended **one-daily-instance** workflow — a single always-open
  no-project window resumes perfectly. And **any window with a folder open is unaffected**:
  project sessions are keyed by their root (D31), so multiple *project* windows stay
  isolated from each other and from the anonymous one.
- **Mitigation in rio.** None automatic today. If you want two independent loose sessions,
  **open a folder** in one of the windows (even a throwaway root) so it gets its own
  per-root session instead of the shared anonymous one.
- **Planned.** A per-instance or last-folder resume pointer would let several no-project
  windows resume independently; noted as the deferred follow-up in AGENTS.md **D72**, not
  yet scheduled.
