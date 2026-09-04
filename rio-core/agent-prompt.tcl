# rio-core — the agent's system prompt: a core-owned, provider-agnostic "soul"
# (AGENTS.md D34, D70).
#
# How the agent behaves — how it uses rio's tools and how it writes code — is a
# CORE concern, not a provider's: the same instructions should shape a turn
# whether the provider is Claude, ChatGPT, the echo stub, or a future local model.
# So the core composes ONE system prompt here and the loop pushes it to the provider
# (the provider contract's `system` argument, agent.tcl), exactly as it already
# pushes `tools`; a provider with no system-prompt slot (echo) simply ignores it.
#
# Three layers, composed in order, deliberately kept apart so a user's own
# instructions never have to live in rio's shipped code. All three are plain
# Markdown DATA — loaded, never executed:
#
#   base (layer 1) — the shipped `agent/prompt.md`: rio's tool contract plus general
#       coding craft. rio's own machinery, not a user knob. Advanced users may swap
#       it wholesale by dropping a replacement at $XDG_CONFIG_HOME/rio/agent/prompt.md.
#
#   system (layer 2, D70) — the user's own `system.md` in the same XDG agent dir:
#       their standing instructions for EVERY project, ADDED on top of the base (it
#       never replaces rio's contract). Opt-in (absent/empty adds nothing).
#
#   project (layer 3) — an optional `.rio/agent.md` at the open project root: the
#       instructions specific to THIS codebase (its conventions, its don'ts). Opt-in,
#       and it lives WITH the project, not with rio.
#
# Layers 2 and 3 are the user-facing prompts, editable from the GUI (Settings ▸ Agent
# Prompts…, which opens each file in rio's own editor via the `agent.prompt.edit` op).
# The composed string is what the provider sends as the request's system prompt; if
# nothing is available at all it is empty and the provider sends none.

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

# The user's own agent dir — where `system.md` lives and where an override `prompt.md`
# would go: $XDG_CONFIG_HOME/rio/agent (or ~/.config/rio/agent). "" only if neither
# XDG_CONFIG_HOME nor HOME is set. A test pins it via override_dirs (its first entry).
proc rio::agent::prompt::_userdir {} {
	variable override_dirs
	if {$override_dirs ne ""} { return [lindex $override_dirs 0] }
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio agent]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio agent]
	}
	return ""
}

# The dirs searched for the base prompt `prompt.md`: the user's agent dir first (so an
# override wins), then the copy shipped beside the source.
proc rio::agent::prompt::_basedirs {} {
	variable override_dirs
	variable srcdir
	if {$override_dirs ne ""} { return $override_dirs }
	set dirs {}
	set ud [_userdir]
	if {$ud ne ""} { lappend dirs $ud }
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

# The user layer (D70): the user's own `system.md` in the XDG agent dir, or "" when
# there is no user dir or no such file. Unlike the base, it is NEVER read from the
# shipped source tree — there is no shipped system prompt; this is the user's alone.
proc rio::agent::prompt::_user {} {
	set d [_userdir]
	if {$d eq ""} { return "" }
	set p [file join $d system.md]
	if {![file isfile $p]} { return "" }
	return [_read $p]
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

# Compose the system prompt the provider will send: the base, then the user's system
# layer, then any project layer — each appended so the more specific refines the more
# general (D70). Any layer may be empty; the result is "" only when nothing is
# available at all.
proc rio::agent::prompt::compose {} {
	set parts {}
	foreach layer {_base _user _project} {
		set t [$layer]
		if {$t ne ""} { lappend parts $t }
	}
	return [join $parts "\n\n"]
}

# The absolute path of a user-editable prompt file — `which` is `system` (the XDG
# `system.md`, all projects) or `project` (`.rio/agent.md`, this project). Returns ""
# when the file cannot be located: no user dir for `system`, or no open project for
# `project`. Pure — the caller (the agent.prompt.edit op) decides how to report "".
proc rio::agent::prompt::path {which} {
	switch -- $which {
		system {
			set d [_userdir]
			if {$d eq ""} { return "" }
			return [file join $d system.md]
		}
		project {
			set root [rio::project::root]
			if {$root eq ""} { return "" }
			return [file join $root .rio agent.md]
		}
		default { return "" }
	}
}

# Resolve a user-editable prompt path and make sure the file exists so an editor can
# open it, creating an EMPTY file (and any parent dir) when absent — empty means the
# layer contributes nothing until the user writes to it; the GUI dialog and the docs,
# not a seeded template, explain what to put there (D70). Returns {path created}, or
# "" if the path cannot be resolved (unknown `which`, no user dir, no open project).
proc rio::agent::prompt::ensure {which} {
	set p [path $which]
	if {$p eq ""} { return "" }
	set created 0
	if {![file isfile $p]} {
		file mkdir [file dirname $p]
		set fh [open $p w] ; fconfigure $fh -encoding utf-8 ; close $fh
		set created 1
	}
	return [dict create path $p created $created]
}
