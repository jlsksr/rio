# rio-core — rio's own release version, and the doctrine behind every version
# number in the tree (AGENTS.md D123).
#
# rio carries TWO kinds of number, and they answer different questions. Reaching for
# the wrong one is the mistake this file exists to prevent.
#
#   A RELEASE version — semver — answers "which rio is this?"
#     That is the number below. ONE number for rio as a whole: core + GUI + the
#     bundled syntax definitions and themes. One git tag per release. It is
#     human-facing — release notes, bug reports, "fixed in 0.2.0" — and nothing
#     branches on it at runtime.
#
#   A CONTRACT version — a monotonic integer — answers "can these two halves talk?"
#     One per seam between two parties that can be updated independently:
#       protocol      GUI <-> core           rio-core/ops-session.tcl
#       provider-api  core <-> provider ext  rio-core/provider.tcl
#       mode-api      GUI  <-> mode ext      rio-gui/rio-gui.tcl
#     These ARE branched on, by an equality or a ceiling test.
#
# Why the seams are not semver. A client asks a contract one question — do I speak
# this? — and answers it with a single comparison. Semver's three components would
# offer an ordering nobody reads and a MINOR/PATCH distinction with no meaning on a
# wire: the rule since D11 is that an ADDITIVE change does not bump at all (fsroot in
# D55, the D120 switch, and the `version` key this file adds to session.hello), so the
# only event the number records is a break. That is what an integer is.
#
# Why one release version and not one per component. Core and GUI are genuinely
# different builds only when the GUI reaches a remote core over --connect (D29/D30),
# and that case is already governed by `protocol`, which answers it precisely. A
# second semver on each half would LOOK like a compatibility statement without being
# one — `core 0.2.1` against `gui 0.2.0` tells a reader nothing the protocol integer
# had not already said.
#
# An extension is versioned on its own timeline (semver, per manifest, D107) and is
# deliberately NOT tied to the number below. That independence is the whole point of
# the *-api integers: they, not rio's version, say what an extension may rely on.
#
# What 1.0.0 will mean, written down now so it is not decided by drift: the
# extension/plugin interface stops being "will change" (ROADMAP) and the protocol is
# something a third-party client can build against. Until then rio stays on 0.x, which
# is the band semver reserves for exactly this.
#
# ONE literal, no second home: rio-gui sources this file from the sibling tree the way
# it already sources wire.tcl and conf.tcl, so the two halves of a checkout cannot
# disagree and need no guard holding them equal.
#
# Bumping it: edit the line below, commit, then tag `v<version>`. The tag is what
# `git describe` reports as About's *Build* — Version says which release line, Build
# says which exact commit, and between releases Build is the precise one.

namespace eval rio {
	variable version 0.1.0
}
