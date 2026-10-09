# rio-core — rio's release version (D123).
#
# rio has two kinds of number:
#
#   release   semver       "which rio is this?"        the number below
#   contract  an integer   "can these two halves talk?"
#
#       protocol      GUI <-> core           rio-core/ops-session.tcl
#       provider-api  core <-> provider ext  rio-core/provider.tcl
#       mode-api      GUI  <-> mode ext      rio-gui/repos.tcl
#
# - One release version for the whole tree, one git tag. Nothing branches on it.
# - A contract is bumped only by a break; an additive change leaves it alone.
# - An extension has its own semver (D107), tied to the contracts, not to this.
# - 1.0.0 means: the extension interface and the protocol are stable.
#
# The GUI sources this file, so there is one literal.
# To bump: edit the line below, commit, tag `v<version>` (RELEASING.md).

namespace eval rio {
	variable version 0.4.1
}
