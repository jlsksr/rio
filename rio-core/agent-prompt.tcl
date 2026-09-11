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
# Five layers, composed in order, deliberately kept apart so a user's own
# instructions never have to live in rio's shipped code. All are plain Markdown
# DATA — loaded, never executed:
#
#   base (layer 1) — the shipped `agent/prompt.md`: rio's tool contract plus general
#       coding craft. rio's own machinery, not a user knob. Advanced users may swap
#       it wholesale by dropping a replacement at $XDG_CONFIG_HOME/rio/agent/prompt.md.
#
#   system (layer 2, D70) — the user's own `system.md` in the same XDG agent dir:
#       their standing instructions for EVERY project, ADDED on top of the base (it
#       never replaces rio's contract). Opt-in (absent/empty adds nothing).
#
#   provider (layer 3, D79) — an optional `providers/<name>.md` in the same XDG agent
#       dir, added ONLY when that provider is the active one: instructions for talking
#       to THIS model (its quirks, a local server's house rules). It still stays a
#       CORE concern — the core picks the file by the active provider's name and folds
#       its text into the one system string; the provider never learns it exists, so
#       the contract is unchanged. Opt-in; `echo` has none (it ignores `system`).
#
#   project (layer 4) — an optional `.rio/agent.md` at the open project root: the
#       instructions specific to THIS codebase (its conventions, its don'ts). The
#       tightest, most task-specific layer of the standing ones, and it lives WITH the
#       project, not with rio. Opt-in.
#
#   plan (layer 5, D101) — the shipped `agent/plan.md`, added ONLY while the agent is in
#       plan mode: how to investigate and what a plan the user will read should say. It
#       comes last because it is momentary — a state the user turned on just now — and it
#       has to outrank anything above it that describes how to make changes. Like the base
#       it is rio's own machinery, so it is shipped and overridable in the XDG agent dir.
#
# Layers 2–4 are the user-facing prompts, editable from the GUI (Preferences ▸ Agent ▸
# Agent Prompts…, which opens each file in rio's own editor via the `agent.prompt.edit` op).
# The composed string is what the provider sends as the request's system prompt; if
# nothing is available at all it is empty and the provider sends none.
#
# NOTHING HERE IS SECRET (D105). The two shipped layers are rio's machinery, but they are
# rio's machinery *about the user's own work*, so they are readable the same way the user's
# own layers are: `layers` inventories every layer — where its file is, where that file came
# from, and whether it is contributing right now — and `text` returns any layer's contents,
# the composed whole included. The frontend shows them; nothing has to be reverse-engineered
# from the source tree, and nothing differs when the core is on another machine (D30).

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

# The file actually in effect for a shipped layer (`prompt.md` / `plan.md`): the first
# one found across the search dirs — the user's override if they wrote one, else rio's
# own copy — or "" if even the shipped copy has gone missing. Normalized, because this
# path is shown to the user (D105) and `..` in the middle of it helps nobody.
proc rio::agent::prompt::_find {file} {
	foreach d [_basedirs] {
		set p [file join $d $file]
		if {[file isfile $p]} { return [file normalize $p] }
	}
	return ""
}

# The base layer: the `prompt.md` in effect, or "" if the shipped file has somehow gone
# missing (the agent then runs with no base prompt — a safe degrade, the same behaviour
# rio had before D34).
proc rio::agent::prompt::_base {} {
	set p [_find prompt.md]
	if {$p eq ""} { return "" }
	return [_read $p]
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

# Whether a provider name is safe to use as a filename: non-empty and only the
# characters a registered provider name uses ([A-Za-z0-9_-]) — no path separators,
# no `..`. Guards the providers/<name>.md path against traversal.
proc rio::agent::prompt::_safe_provider {name} {
	return [expr {$name ne "" && [regexp {^[A-Za-z0-9_-]+$} $name]}]
}

# The per-provider layer (D79): `providers/<name>.md` in the XDG agent dir, for the
# ACTIVE provider only. "" when no name is given, the name is `echo` (it ignores the
# system prompt) or unsafe, there is no user dir, or the file is absent. Like _user,
# it is NEVER read from the shipped source tree — this is the user's alone.
proc rio::agent::prompt::_provider {name} {
	if {$name eq "" || $name eq "echo" || ![_safe_provider $name]} { return "" }
	set d [_userdir]
	if {$d eq ""} { return "" }
	set p [file join $d providers $name.md]
	if {![file isfile $p]} { return "" }
	return [_read $p]
}

# The plan layer (D101): the shipped `agent/plan.md`, added only while the agent is in
# plan mode. Found the same way as the base — the user's agent dir first, so a user who
# wants the agent to plan differently drops their own `plan.md` there — because this is
# rio's machinery speaking, not the user's standing instructions. "" in build mode, and ""
# if the shipped file is missing (plan mode then still withholds the editing tools, which
# is the half that does not depend on the model reading anything).
proc rio::agent::prompt::_plan {mode} {
	if {$mode ne "plan"} { return "" }
	set p [_find plan.md]
	if {$p eq ""} { return "" }
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
# layer, then the active provider's own layer, then any project layer — each appended
# so the more specific refines the more general (D70/D79). `provider` is the active
# provider's NAME (the caller passes rio::agent::provider_name); "" (or echo) simply
# contributes no provider layer. `mode` adds the plan layer while the agent is planning
# (D101) — last, because it is the most situational thing said here and it has to win
# over anything above it that says how to make changes. Any layer may be empty; the
# result is "" only when nothing is available at all.
proc rio::agent::prompt::compose {{provider ""} {mode build}} {
	set parts {}
	foreach t [list [_base] [_user] [_provider $provider] [_project] [_plan $mode]] {
		if {$t ne ""} { lappend parts $t }
	}
	return [join $parts "\n\n"]
}

# Where a resolved file came from, for the inventory (D105): `user` when it sits in the
# user's own agent dir (their layer, or their override of a shipped one), `project` when
# it is the open project's `.rio/agent.md`, `shipped` for rio's own copy beside the
# source, and `none` when there is no file at all. Told from the path rather than from
# which accessor found it, so an override is recognisable as an override.
proc rio::agent::prompt::_origin {path} {
	if {$path eq ""} { return none }
	set p [file normalize $path]
	set ud [_userdir]
	if {$ud ne "" && [string match [file normalize $ud]/* $p]} { return user }
	set root [rio::project::root]
	if {$root ne "" && [string match [file normalize $root]/* $p]} { return project }
	return shipped
}

# One row of the inventory: what this layer's file is, where it came from, and whether it
# is saying anything right now. `chars` is the length of what the layer's file SAYS and
# `active` is whether compose() is currently including it — two different questions, kept
# apart on purpose: a plan layer full of text that build mode is not using is not the same
# state as an empty file, and telling the user "empty" about either would be a lie about
# the other.
proc rio::agent::prompt::_entry {which name path builtin text active} {
	set exists [expr {$path ne "" && [file isfile $path]}]
	return [dict create which $which name $name path $path \
		origin [expr {$exists ? [_origin $path] : "none"}] \
		exists $exists builtin $builtin \
		active [expr {$active && $text ne ""}] chars [string length $text]]
}

# One layer's inventory row: {which, name, path, origin, exists, builtin, active, chars},
# or "" for an unknown `which`. `path` is the file this layer is actually READING — rio's
# own copy or the user's override for the two shipped layers, the layer's own file for the
# user's three — which is not always where a new copy would be WRITTEN (that is `path`,
# below).
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

# The whole prompt, layer by layer, in composition order (D105) — the inventory behind the
# frontend's prompt list. `builtin` marks rio's own two layers (base, plan): they ship with
# rio and are overridden rather than edited, which is a different offer from the user's own
# three. `provider` names the live provider and `mode` the live mode, because the honest
# answer to "what is in effect" depends on both.
proc rio::agent::prompt::layers {{provider ""} {mode build}} {
	set out {}
	foreach w {base system provider project plan} {
		lappend out [layer $w [expr {$w eq "provider" ? $provider : ""}] $mode]
	}
	return $out
}

# One layer's text, for reading rather than for composing (D105): `base`, `system`,
# `provider` (with `name`), `project`, `plan`, or `composed` — the finished string the
# provider would be sent right now. The `plan` layer is returned whatever the current
# mode is: the user asked to read it, which is not the same question as whether it is
# live. Unknown names return "" rather than raising; the op above decides what to report.
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

# The absolute path of a prompt file the user may write — `which` is `system` (the XDG
# `system.md`, all projects), `provider` (the XDG `providers/<name>.md`, for the named
# provider), `project` (`.rio/agent.md`, this project), or one of the two shipped layers,
# `base` / `plan`, whose writable path is the OVERRIDE in the user's agent dir (rio's own
# copy is never the thing you edit — it may be read-only, and an upgrade would take your
# changes away). Returns "" when the path cannot be located: no user dir, an unsafe/empty
# `name` for `provider` — `echo` included, since it ignores the system prompt entirely and
# a file it can never read is not a path worth offering — or no open project for `project`.
# Pure — the caller (the agent.prompt.edit op) decides how to report "".
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

# Resolve a writable prompt path and make sure the file exists so an editor can open it,
# creating it (and any parent dir) when absent. Returns {path created}, or "" if the path
# cannot be resolved (unknown `which`, no user dir, no open project, or an unsafe provider
# `name`).
#
# What a new file starts as depends on what it is. A USER layer starts EMPTY: empty means
# the layer contributes nothing until they write to it, and the dialog and the docs — not
# a seeded template — explain what belongs there (D70). An OVERRIDE of a shipped layer
# (base, plan) starts as a COPY of the text it overrides (D105), because an empty
# `prompt.md` does not mean "no opinion", it means "rio's instructions are deleted" — and
# nobody clicking *customise* means that. Copying is also the honest form of the offer:
# what you get is exactly what was in effect a moment ago, there to be edited.
proc rio::agent::prompt::ensure {which {name ""}} {
	set p [path $which $name]
	if {$p eq ""} { return "" }
	set created 0
	if {![file isfile $p]} {
		# Read the seed BEFORE creating the file: `text base` searches the user dir
		# first, so an empty file created here would become its own seed.
		set seed [expr {$which in {base plan} ? [text $which] : ""}]
		file mkdir [file dirname $p]
		set fh [open $p w] ; fconfigure $fh -encoding utf-8
		if {$seed ne ""} { puts $fh $seed }
		close $fh
		set created 1
	}
	return [dict create path $p created $created]
}
