# ADR-0134: A headless run must not be able to receive real input

- **Status:** Accepted
- **Date:** 2026-09-21
- **Deciders:** jka
- **Decision log:** AGENTS.md D127

## Context

rio's GUI suites run under `RIO_GUI_HEADLESS`, which is the same X display the developer is
working on. One suite failed about one run in twelve, and failed in a way nothing rio computes
could explain: a buffer every suite assumes is empty was not, and a later check read back a
label with a stray letter in front of the text it expected — a different letter each run.

The letter was a keystroke of the developer's, typed into the test's own window. A headless run
maps its toplevel, and on X11 a click-to-focus window manager hands a newly mapped window the
input focus. Measured through the map, `xprop` and Tk agreeing, the focus landed on the boot
editor widget itself, where Tk's Text class binding inserts whatever arrives. Delivering a
single key press at that instant reproduced both observed failures exactly, and the run was
clean when no key arrived. One in twelve is simply how often a key happened to be down during
those milliseconds.

The map cannot be dropped. Windows never sizes an unmapped toplevel at all, so every child
collapses with it and any check asking whether something fits its pane reads an answer from a
layout nothing could fit in. X11 does size an unmapped toplevel, but a `panedwindow` lays its
panes out only once mapped, and rio's editor groups are panes of one, so without the map the
editor and the group around it sit at 1x1 while everything else measures correctly.

The failure was invisible on CI and only ever bit a display with a human at it, so re-running
made it go away. That is the worst property a flake can have, and it was recorded nowhere.

## Decision

A headless run may have a window with real geometry, but the window manager must never see
that window, and the run must never hold the X input focus. Three parts, all in the GUI's boot
path.

**The window is withdrawn before anything can map it,** at the very top of the file. Nothing in
rio maps the toplevel on purpose; the first entry into the event loop does, and boot is full of
them, because every blocking operation call waits on its reply. A suite talking to an
in-process core gets replies too fast for the map to matter; a suite that spawns a core waits
long enough to be mapped every time.

**The sizing map runs with the window manager taken out of it,** under `wm overrideredirect`.
The window is mapped and viewable, so the geometry is real and every widget measures exactly as
it did before, but the window is never managed and therefore cannot be given the focus. The
override is set for the duration of that one map and cleared after it.

**A tripwire records the focus at boot and fails the run at exit.** `focus -displayof .` names a
widget only when the X input focus really belongs to this application, so a non-empty answer at
boot means the run could have taken a keystroke. It fails the run in the idiom
[ADR-0095](0095-headless-never-asks.md) established for dialogs, because stray input is the
same class of bug: something from outside the suite deciding the result. Only a check on the
result could have found this at all — the tripwire showed four further suites leaking the focus
through the event loop rather than through the sizing map. It is not armed on Windows, where a
mapped window is window-manager-managed by definition.

The invariant is the title of this record, not the flake that exposed it.

## Alternatives considered

- **Skip the map on the platform that never needed it** — map on Windows, settle for pending
  idle work on X11. This was the planned fix, and measurement rejected it before it was
  committed: X11 sizes an unmapped toplevel, but the panes of a `panedwindow` are laid out only
  once it is mapped, so the editor and its group dropped to 1x1 while their neighbours measured
  correctly.
- **Keep the map and filter the keys** — a global key binding that records stray keystrokes and
  tells a real one from the suite's own synthetic events by timestamp. It records the damage
  instead of preventing it, since the Text class binding has already inserted the character
  before any application-wide binding runs, and the timestamp discrimination could not be
  verified without a human at the keyboard to press a key. A precondition check needs neither.
- **Install Xvfb and give the suites their own display.** Rejected: a build-time dependency
  added to chase a flake, and it only moves the run somewhere the bug cannot be seen. A
  deterministic reproduction is better evidence than a clean statistical run
  ([ADR-0116](0116-verification-policy.md)).
- **Declare the suites unsupported on a display in use.** The same objection, without the
  dependency. It would have left rio able to take a keyboard it was never supposed to have.

## Consequences

- A headless run cannot receive real input on X11, and a regression in either half of the fix
  fails the run rather than corrupting one check in twelve.
- The headless window keeps real geometry, so checks about what fits a pane stay meaningful on
  both platforms.
- The Windows leg is unverified from Linux: there the map is the shape it always was, with the
  window additionally undecorated for the moment it is up, and the tripwire is deliberately not
  armed. A collapsed layout on Windows is the first place to look.
- CAVEATS.md carries the symptom, so the next person to meet a stray character in a test buffer
  can recognise it instead of re-running.
- The cost of the guard is one read of the focus at boot and one check at exit.
