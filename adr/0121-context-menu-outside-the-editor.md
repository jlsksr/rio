# ADR-0121: A context menu on every text widget outside the editor

- **Status:** Accepted
- **Date:** 2026-09-17
- **Deciders:** jka
- **Decision log:** AGENTS.md D115

## Context

ADR-0108 gave the editor a right-click menu and stopped there on purpose: the read-only
views (agent log, compare panes, git diff, the manual, a plan) and the entry and text
widgets outside the editor were named as "its own later change". In all of them the
clipboard keystrokes already worked, through Tk's own class bindings; only the menu was
missing, on surfaces whose every neighbour in rio — file rows, git rows, tab handles, dock
tabs, the editor — answers a right-click. Someone who reaches for the mouse in the first
hour finds a dead button, which is why this was taken before a release rather than left in
the backlog.

## Decision

**The text widgets get the menu, in two families**, applied at each widget's creation
site:

| | applies to | entries |
| --- | --- | --- |
| view | read-only text views | Copy, Select All |
| input | entry and text widgets outside the editor | Cut, Copy, Paste, ─, Select All |

**The commands generate Tk's own virtual events** — `<<Cut>>`, `<<Copy>>`, `<<Paste>>`,
`<<SelectAll>>` — rather than calling rio's clipboard procedures. These are ordinary local
Tk widgets whose Ctrl+X/C/V *is* the Entry or Text class binding, so generating the same
event makes the menu and the keystroke one implementation by construction, with no second
clipboard path to keep in step. The editor is the opposite case: an edit there must reach
the core through the group proxy (ADR-0003), which is why ADR-0108 correctly used rio's
own commands.

**A read-only view is offered no Cut and no Paste at all** — absent, not greyed. The
widget would refuse them, and an entry that can never work should not be drawn. ADR-0108's
rule that only honestly computable states are greyed still holds for the rest: Cut and
Copy follow the selection, Select All follows the content, and **Paste stays enabled** on
an input for ADR-0108's reason unchanged — probing the clipboard is a blocking round-trip
to whichever application owns the selection, and an unresponsive owner would stall the
menu on its way up.

**A masked field withholds Cut and Copy.** The provider API-key entry offers Paste and
Select All only: pasting a key is what people do there, while lifting plaintext out of a
field drawn as bullets is a surprise, and ADR-0026 treats a key as a secret.

**The click keeps ADR-0108's convention minus the half a read-only view cannot.** A click
inside the selection leaves it alone; a click outside clears it. The caret moves only in
an editable widget, because a disabled text draws no insertion cursor and moving it would
promise something nothing on screen keeps. The keyboard route (Menu, Shift+F10) posts at
the caret for an input, at the start of the selection for a view, and at the widget's
top-left when there is neither.

**A placeholder label placed on top of a field forwards the right-click** to the field
below, as it already forwards the left-click; otherwise a right-click on an empty commit
bar would hit the label and reach nothing.

**The row lists stay out.** Files and Git already have real row menus. Search results and
the manual's contents have their right-click bound to an empty callback, and filling it
means deciding what Copy or Open mean for a result row — a Search and Help feature, not
the missing door this decision is about. Those panes also suppress text selection, so a
Copy there could not be the copy this menu offers.

## Alternatives considered

**Reusing rio's own editor clipboard commands**, which already accept a target widget and
would have worked. Rejected because in these widgets the keystroke is the class binding;
routing the menu through rio's commands would create a second implementation of the same
action that could drift from the key the user presses.

**Covering the row lists too.** Rejected: it is a feature decision for Search and Help
about what their rows offer, and it would arrive as a menu whose Copy cannot copy a
selection the pane does not allow.

**Greying Cut and Paste on a read-only view** instead of omitting them. Rejected: a
permanently dead entry teaches the user nothing and makes the menu longer than the widget
is capable of.

**Offering Cut and Copy on the masked key field.** Rejected under ADR-0026: the field is
drawn masked precisely so the secret is not on screen, and a menu that hands it to the
clipboard undoes that.

## Consequences

- Every text surface in rio answers a right-click, with the same click convention as the
  editor.
- The menu cannot drift from the clipboard keystrokes, because it fires them.
- A guard sweeps the live widget tree rather than a list: every entry and text widget in
  the main window must carry a right-click binding, from here, from ADR-0108 or from the
  rich-list component, so a widget added bare later fails by existing.
- Search results and the manual's contents still have no context menu, and will not until
  someone decides what their rows offer.
- A widget covered by a placed overlay needs the forward explicitly; the sweep catches the
  widget, not the label on top of it.
