# ADR-0123: rio has a window and taskbar icon

- **Status:** Accepted
- **Date:** 2026-09-18
- **Deciders:** jka
- **Decision log:** AGENTS.md D117

## Context

rio set no `_NET_WM_ICON`, so nothing told the desktop what the window looked like. The
window manager and the panel each fell back to a default of its own, which is why the
title bar and the taskbar showed two *different* generic icons for the same window. The
maintainer supplied the artwork: Christ the Redeemer, a pun on the project's name.

ADR-0027 limits rio's iconography to monochrome Unicode glyphs. That rule governs the
iconic controls rio draws inside its own UI, where a font is the right tool and scales
with the text for free. `_NET_WM_ICON` is a different surface: it takes pixels, and a
glyph would have to be rendered to a pixmap to reach it at all. A window icon is
therefore outside ADR-0027 rather than an exception to it, and ADR-0027 stands unamended.

## Decision

**rio ships raster window icons and hands the whole set to the window manager.** Several
sizes are given at once and the desktop picks what it wants — small for the title bar,
middling for alt-tab, large for a window list. The set is applied as the default for
every toplevel, so dialogs and the help window inherit it without each repeating the
call.

**The icons are a soft dependency of the same kind as tkdnd (ADR-0086).** The files are
only ever read, never required: with the icon directory missing, incomplete or
unreadable, rio starts exactly as it did before and the desktop uses its own default.
Loading an image is never allowed to abort start-up.

**No new dependency.** Tk 8.6's `photo` reads PNG natively, which was verified rather
than assumed, so rio's dependency bar (ADR-0115) is untouched.

**A Windows `.ico` sits beside the PNGs.** `wm iconphoto` works on Windows, but the
taskbar and alt-tab render a real `.ico` better, so one is shipped and used there.

**The set is cut from the artwork by a script in the icons directory, and that script is
not part of any build.** Its output is committed; rio never runs it, at start-up or at
install time. It exists so that replacing the artwork is one command, and so that what
was learned about cutting this artwork is written down where the next person will cut the
next one. It needs ImageMagick, which is a contributor's tool and not a dependency of rio.
What it encodes: trim the source's transparent margin before scaling, because at the
smallest size that slack costs whole pixels of the subject; and scale with Lanczos and no
sharpening.

**Every artwork rio has worn is kept, and one committed line names the one in force.**
The sources sit together in `sources/` under a name each, and `active` records which of
them the cut PNGs came from. The script lists the candidates, switches to one by name, or
adopts a new file by path. Going back to an earlier icon is therefore the same command
with a different name, and the diff of that one line states which icon a commit changed
rio to — something a set of re-cut binary PNGs cannot say.

**The size list the loader asks for is a variable, not a literal inside the loop**, so
the guard that holds it against the files on disk can ask what was requested instead of
reading the loader's source text (ADR-0116).

## Alternatives considered

**Sharpening the downscales.** An unsharp mask is standard practice when cutting icons,
and the result looked right at 48 pixels. Magnified at 16 it rings: a dark halo along the
edge of the pedestal. Rejected on the size that matters most.

**Deriving a high-contrast variant for the smallest sizes by post-processing** — a dark
silhouette where the artwork is weakest. It cannot be done: the disc's pale yellow and
the statue's beige highlights are too close for a colour key to separate them. Two
attempts bled, one reducing the whole icon to a dark blob. The fix belongs in the source
artwork, not downstream of it.

**Keeping one source image and overwriting it.** That is how the set was first cut. It
makes every change of artwork a destructive edit of a binary file, leaves the commit
unable to say which icon it moved rio to, and makes going back a matter of finding the
old file again. Keeping the candidates costs a few tens of kilobytes each.

**tkimg for image loading.** Never needed, and it would have added a fourth hard
dependency to carry a decorative asset.

**Making the cut a build step.** Rejected: it would make ImageMagick a requirement for
anyone building or installing rio, to reproduce files that change only when the artwork
does.

## Consequences

- The title bar, the taskbar and alt-tab show the same icon, and every window rio opens
  inherits it.
- The artwork is now an asset the project maintains. Changing it means re-cutting the
  set and committing the result; nothing downstream of the committed PNGs can be tuned
  per size. Because the candidates are kept, reverting that change costs exactly what
  making it cost.
- The first artwork was accepted with a limit at 16 pixels — the title-bar and taskbar
  size, which is the size this decision exists for: its pale-yellow disc read well on dark
  window chrome and washed out on light, and nothing downstream of the source could mend
  it. That limit is closed where it had to be. A second artwork, a mid-blue disc inside a
  dark outline, was cut alongside the first and compared at 16, 24 and 32 pixels over both
  dark and light backgrounds; it is better at every size and is now the active one. The
  first is kept.
- What that comparison settled outlives this icon. At 16 pixels an icon is carried by the
  contrast at the edge of its largest shape, not by anything inside it, and the case it
  fails is the window chrome it was not designed against. An artwork intended for a window
  icon needs a hard outline and needs to hold against both a light and a dark title bar.
- A size that the loader asks for but nobody cut, or a file nobody asks for, would
  otherwise fail silently — the desktop simply falls back, which looks like nothing being
  wrong. The set on disk and the set requested are therefore held against each other in
  both directions.
