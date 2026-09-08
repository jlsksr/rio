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
- **At scale (planned).** Grouping bounds the *fixed* menus, but two menus are
  **data-driven and unbounded** — the **Theme** cascade (grows with installed themes, D39)
  and the **Tabs** menu (one entry per open buffer) — and those can still outgrow the
  screen. The durable fix is to render *those two* as rio's scrollable `rl_*` rich-list
  picker (the same component the Files / Git / Extensions panes use), which has a bounded
  height and a scrollbar and never posts a screen-tall menu. Tracked under *Menu overflow
  at scale* in [ROADMAP.md](ROADMAP.md).

---

## Behavioural limitations

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
