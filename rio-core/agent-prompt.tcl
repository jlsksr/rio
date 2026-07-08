# rio-core — the agent's system prompt: a core-owned, provider-agnostic "soul"
# (AGENTS.md D34).
#
# How the agent behaves — how it uses rio's tools and how it writes code — is a
# CORE concern, not a provider's: the same instructions should shape a turn
# whether the provider is Claude, the echo stub, or a future local model. So the
# core composes ONE system prompt here and the loop pushes it to the provider (the
# provider contract's `system` argument, agent.tcl), exactly as it already pushes
# `tools`; a provider with no system-prompt slot (echo) simply ignores it.
#
# Three layers, composed in order, deliberately kept apart so a user's personal
# style never has to live in rio's shipped code:
#
#   base (layers 1+2) — the shipped `agent/prompt.md`: rio's tool contract plus
#       general coding craft. Model-neutral, plain DATA (loaded, never executed),
#       and swappable exactly like a theme or a highlighter — drop a replacement
#       at $XDG_CONFIG_HOME/rio/agent/prompt.md to override the shipped one.
#
#   project (layer 3) — an optional `.rio/agent.md` at the open project root: the
#       instructions specific to THIS codebase (its conventions, its don'ts). Fully
#       opt-in (absent means nothing is added), and it lives WITH the project, not
#       with rio — this is where a user's own workflow goes without baking it in.
#
# The composed string is what the provider sends as the request's system prompt;
# if nothing is available at all it is empty and the provider sends none.

namespace eval rio::agent::prompt {
	# Captured at SOURCE time (like rio::theme): the shipped base lives beside the
	# source tree, one level up in `agent/`.
	variable srcdir [file dirname [file normalize [info script]]]
	variable override_dirs ""   ;# tests pin the base-file search here
}

# Let a test point the base-file search at a sandbox dir (mirrors
# rio::theme::override_dirs). "" restores the real XDG-then-shipped search.
proc rio::agent::prompt::override_dirs {dirs} {
	variable override_dirs
	set override_dirs $dirs
}

# The dirs searched for the base prompt `prompt.md`: the user's XDG agent dir
# first (so an override wins), then the copy shipped beside the source.
proc rio::agent::prompt::_basedirs {} {
	variable override_dirs
	variable srcdir
	if {$override_dirs ne ""} { return $override_dirs }
	set dirs {}
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		lappend dirs [file join $::env(XDG_CONFIG_HOME) rio agent]
	} elseif {[info exists ::env(HOME)]} {
		lappend dirs [file join $::env(HOME) .config rio agent]
	}
	lappend dirs [file join $srcdir .. agent]
	return $dirs
}

# The base layer: the first `prompt.md` found across the search dirs, or "" if the
# shipped file has somehow gone missing (the agent then runs with no base prompt —
# a safe degrade, the same behaviour rio had before D34).
proc rio::agent::prompt::_base {} {
	foreach d [_basedirs] {
		set p [file join $d prompt.md]
		if {[file isfile $p]} { return [_read $p] }
	}
	return ""
}

# The project layer: `.rio/agent.md` at the open project root, or "" when there is
# no open project or no such file. Per-project instructions live with the project.
proc rio::agent::prompt::_project {} {
	set root [rio::project::root]
	if {$root eq ""} { return "" }
	set p [file join $root .rio agent.md]
	if {![file isfile $p]} { return "" }
	return [_read $p]
}

# Read a prompt file as UTF-8 text, trimmed of surrounding whitespace so the
# layers join cleanly. A read failure degrades to "" rather than breaking a turn.
proc rio::agent::prompt::_read {path} {
	if {[catch {
		set fh [open $path r]
		fconfigure $fh -encoding utf-8
		set data [read $fh]
		close $fh
	}]} { return "" }
	return [string trim $data]
}

# Compose the system prompt the provider will send: the base, then any project
# layer appended (so a project's instructions refine the general ones). Either
# layer may be empty; the result is "" only when nothing is available at all.
proc rio::agent::prompt::compose {} {
	set parts {}
	foreach layer {_base _project} {
		set t [$layer]
		if {$t ne ""} { lappend parts $t }
	}
	return [join $parts "\n\n"]
}
