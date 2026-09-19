# The artwork rio's icon is cut from

Every artwork rio has worn lives here under a name of its own, and `../active` (one
committed line) says which one the `rio-*.png` set was cut from. `../make-icons.sh`
switches between them; nothing here is ever overwritten.

## Where these come from

### `redeemer-1.png`

The project's own. Made by jka on 2026-09-20 from a prompt of jka's, with ChatGPT.
rio may ship it, and anyone may redistribute a copy of rio with it — which is the whole
requirement (see below).

## What may go in this folder

**Only artwork this project can redistribute without conditions it has to keep track
of.** rio is copied wholesale — cloned, packaged, mirrored — and an icon travels with
every copy. An artwork whose licence makes *redistributing the file itself* uncertain is
a liability in every one of those copies, not just in this repository.

That is why the three Flaticon Redeemer variants that preceded this one were removed
rather than re-credited. Their free licence requires attribution, which is easy, but what
it permits downstream of a git clone was not clear enough to build a release on. The
question is not "may we use it" but "may everyone who receives rio pass it on".

**Adding one?** Put its origin above in the same commit that adds the file — who made
it, when, and on what terms rio may pass it on. Every artwork in this folder needs that
whether or not it is the one currently worn: they all ship in the repository, and
`active` decides only which one rio wears.
