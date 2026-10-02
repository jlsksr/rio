# rio-core — the agent's system prompt (D34, D70).
#
# The core composes one system prompt and hands it to whichever provider is
# active, so every model gets the same instructions. Five Markdown layers,
# joined in this order. They are data: loaded, never executed.
#
#   layer     file                              whose   when
#   base      agent/prompt.md                   rio's   always
#   system    <xdg>/system.md                   user's  always (D70)
#   provider  <xdg>/providers/<name>.md         user's  that provider is active (D79)
#   project   <root>/.rio/agent.md              user's  that project is open
#   plan      agent/plan.md                     rio's   plan mode only (D101)
#
#   <xdg> is $XDG_CONFIG_HOME/rio/agent.
#
# - A later layer refines an earlier one. Plan is last so it outranks them all.
# - A user layer is opt-in: absent or empty adds nothing.
# - A copy of prompt.md or plan.md in <xdg> replaces rio's.
# - Every layer is readable (D105): `layers` lists them, `text` returns one.
#   The GUI shows them under Preferences ▸ Agent ▸ Agent Prompts….

namespace eval rio::agent::prompt {
	# Set at source time: the shipped files are in `agent/`, one level up.
	variable srcdir [file dirname [file normalize [info script]]]
	variable override_dirs ""   ;# tests pin the base-file search here
}

# Let a test point the search at a sandbox dir. "" restores the real one.
proc rio::agent::prompt::override_dirs {dirs} {
	variable override_dirs
	set override_dirs $dirs
}

# The user's agent dir: $XDG_CONFIG_HOME/rio/agent, or ~/.config/rio/agent.
# "" if neither variable is set. Under a test: the first of override_dirs.
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

# The dirs searched for a shipped layer: the user's first, so an override wins.
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

# The file in effect for a shipped layer (`prompt.md`, `plan.md`), or "".
# Normalized, because the user sees this path (D105).
proc rio::agent::prompt::_find {file} {
	foreach d [_basedirs] {
		set p [file join $d $file]
		if {[file isfile $p]} { return [file normalize $p] }
	}
	return ""
}

# The base layer: the `prompt.md` in effect. "" if it is missing; the agent
# then runs without a base prompt.
proc rio::agent::prompt::_base {} {
	set p [_find prompt.md]
	if {$p eq ""} { return "" }
	return [_read $p]
}

# The system layer (D70): the user's `system.md`, or "". Never read from the
# shipped tree.
proc rio::agent::prompt::_user {} {
	set d [_userdir]
	if {$d eq ""} { return "" }
	set p [file join $d system.md]
	if {![file isfile $p]} { return "" }
	return [_read $p]
}

# Is a provider name safe as a filename? Only [A-Za-z0-9_-], so no path
# separator and no `..` reaches providers/<name>.md.
proc rio::agent::prompt::_safe_provider {name} {
	return [expr {$name ne "" && [regexp {^[A-Za-z0-9_-]+$} $name]}]
}

# The provider layer (D79): the user's `providers/<name>.md`, or "". `echo`
# has none: it ignores the system prompt.
proc rio::agent::prompt::_provider {name} {
	if {$name eq "" || $name eq "echo" || ![_safe_provider $name]} { return "" }
	set d [_userdir]
	if {$d eq ""} { return "" }
	set p [file join $d providers $name.md]
	if {![file isfile $p]} { return "" }
	return [_read $p]
}

# The plan layer (D101): the `plan.md` in effect, in plan mode only. If the
# file is missing, plan mode still withholds the editing tools.
proc rio::agent::prompt::_plan {mode} {
	if {$mode ne "plan"} { return "" }
	set p [_find plan.md]
	if {$p eq ""} { return "" }
	return [_read $p]
}

# The project layer: `.rio/agent.md` at the open project root, or "".
proc rio::agent::prompt::_project {} {
	set root [rio::project::root]
	if {$root eq ""} { return "" }
	set p [file join $root .rio agent.md]
	if {![file isfile $p]} { return "" }
	return [_read $p]
}

# Read a prompt file as UTF-8, trimmed. A read failure gives "": it must not
# break a turn.
proc rio::agent::prompt::_read {path} {
	if {[catch {
		set fh [open $path r]
		fconfigure $fh -encoding utf-8
		set data [read $fh]
		close $fh
	}]} { return "" }
	return [string trim $data]
}

# The system prompt: every non-empty layer, joined by a blank line.
# `provider` is the active provider's name; `mode` is build or plan.
proc rio::agent::prompt::compose {{provider ""} {mode build}} {
	set parts {}
	foreach t [list [_base] [_user] [_provider $provider] [_project] [_plan $mode]] {
		if {$t ne ""} { lappend parts $t }
	}
	return [join $parts "\n\n"]
}

# Where a file came from (D105): user | project | shipped | none. Told from
# the path, so an override of a shipped layer reads as `user`.
proc rio::agent::prompt::_origin {path} {
	if {$path eq ""} { return none }
	set p [file normalize $path]
	set ud [_userdir]
	if {$ud ne "" && [string match [file normalize $ud]/* $p]} { return user }
	set root [rio::project::root]
	if {$root ne "" && [string match [file normalize $root]/* $p]} { return project }
	return shipped
}

# One row of the inventory. `chars` is how much the file says; `active` is
# whether compose() includes it now. Two questions: a full plan layer in build
# mode is not an empty file.
proc rio::agent::prompt::_entry {which name path builtin text active} {
	set exists [expr {$path ne "" && [file isfile $path]}]
	return [dict create which $which name $name path $path \
		origin [expr {$exists ? [_origin $path] : "none"}] \
		exists $exists builtin $builtin \
		active [expr {$active && $text ne ""}] chars [string length $text]]
}

# One layer's row: {which name path origin exists builtin active chars}, or ""
# for an unknown `which`. `path` is the file being read. Where a new copy would
# be written is the proc `path`, below.
proc rio::agent::prompt::layer {which {name ""} {mode build}} {
	switch -- $which {
		base     { return [_entry base     $name [_find prompt.md]     1 [_base]           1] }
		system   { return [_entry system   $name [path system]         0 [_user]           1] }
		provider { return [_entry provider $name [path provider $name] 0 [_provider $name] 1] }
		project  { return [_entry project  $name [path project]        0 [_project]        1] }
		plan     { return [_entry plan     $name [_find plan.md]       1 [_plan plan] \
			[expr {$mode eq "plan"}]] }
	}
	return ""
}

# Every layer's row, in composition order (D105). `builtin` marks rio's two
# (base, plan), which are overridden, not edited.
proc rio::agent::prompt::layers {{provider ""} {mode build}} {
	set out {}
	foreach w {base system provider project plan} {
		lappend out [layer $w [expr {$w eq "provider" ? $provider : ""}] $mode]
	}
	return $out
}

# One layer's text, for reading (D105). `which` is a layer, or `composed` for
# the string a provider would get now. `plan` is returned in any mode.
# An unknown `which` gives "".
proc rio::agent::prompt::text {which {name ""} {provider ""} {mode build}} {
	switch -- $which {
		base     { return [_base] }
		system   { return [_user] }
		provider { return [_provider $name] }
		project  { return [_project] }
		plan     { return [_plan plan] }
		composed { return [compose $provider $mode] }
	}
	return ""
}

# The path of the file the user may write for a layer. For `base` and `plan`
# that is the override in the user's dir: rio's own copy is never edited, an
# upgrade would replace it.
# "" when there is none: no user dir, no open project, an unsafe provider
# name, or `echo`.
proc rio::agent::prompt::path {which {name ""}} {
	switch -- $which {
		base - plan {
			set d [_userdir]
			if {$d eq ""} { return "" }
			return [file join $d [expr {$which eq "base" ? "prompt.md" : "plan.md"}]]
		}
		system {
			set d [_userdir]
			if {$d eq ""} { return "" }
			return [file join $d system.md]
		}
		provider {
			if {$name eq "echo" || ![_safe_provider $name]} { return "" }
			set d [_userdir]
			if {$d eq ""} { return "" }
			return [file join $d providers $name.md]
		}
		project {
			set root [rio::project::root]
			if {$root eq ""} { return "" }
			return [file join $root .rio agent.md]
		}
		default { return "" }
	}
}

# Make sure a layer's writable file exists, so an editor can open it.
# Returns {path created}, or "" if `path` gives none.
#
# - A user layer starts empty (D70).
# - An override of base or plan starts as a copy of what it overrides (D105):
#   an empty `prompt.md` would delete rio's instructions.
proc rio::agent::prompt::ensure {which {name ""}} {
	set p [path $which $name]
	if {$p eq ""} { return "" }
	set created 0
	if {![file isfile $p]} {
		# Read the seed before creating the file, or the empty file is its own seed.
		set seed [expr {$which in {base plan} ? [text $which] : ""}]
		file mkdir [file dirname $p]
		set fh [open $p w] ; fconfigure $fh -encoding utf-8
		if {$seed ne ""} { puts $fh $seed }
		close $fh
		set created 1
	}
	return [dict create path $p created $created]
}
