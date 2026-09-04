# rio — cross-platform caveats

A running list of **behaviour differences across platforms**: cases where the *same*
rio code behaves differently on one OS / window manager / toolkit than on another.
These are usually traits of Tk or the surrounding environment rather than bugs in
rio's own code — but they are real, and worth tracking so we remember the mitigation
and don't re-discover them the hard way.

Each entry records the **symptom**, the **cause**, **where it's fine**, rio's current
**mitigation**, and any **planned** work (with a pointer to [ROADMAP.md](ROADMAP.md) /
[AGENTS.md](AGENTS.md)). When you hit a new "works here, not there" quirk, append it here.

---

## Over-tall menus close on hover (X11)

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
