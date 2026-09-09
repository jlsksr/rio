# rio-core — the agent's command allow-list: standing approval for trusted commands
# (AGENTS.md D84). D83 landed run_command ALWAYS gated — every command waits for a
# human. This adds a human-authored allow-list so a command the user has marked
# trusted runs without re-raising the bar. It is standing approval, not autonomy: a
# person still authored every rule (D53 / [[llm-integration-scope]]). The allow-list
# skips ONLY the approval bar — an allowed command still passes the full prepare_exec
# gauntlet (redirection guard, project-confined cwd, timeout clamp).
#
# A rule is an argv PREFIX: a Tcl list of leading tokens. A command matches when its
# argv starts with a rule's tokens (exact string per token). A one-token rule
# (`pytest`) trusts the program with any arguments; a full-argv rule trusts only that
# exact command. There is no shell and no globbing — matching is plain token compare.
#
# THREE SCOPES, mirroring the system-prompt layers (D79/D70) one-to-one:
#   global   — `allow.list` in the XDG agent dir; every project, always active.
#   provider — `providers/<name>.allow.list` in the XDG agent dir; active only while
#              that provider is the running one (echo excluded, as it ignores tools).
#   project  — `.rio/allow.list` at the open project root; active only in that project.
# Each file is one rule per line, a Tcl list; `#` lines and blanks ignored, so all
# three stay hand-editable. `matches` is the UNION of the currently-active layers: a
# command is trusted if ANY active layer allows it (the allow-list analog of how the
# prompt layers all apply together). There is no precedence — a match anywhere is enough.

namespace eval rio::agent::allow {
	variable override_dir ""   ;# tests pin the XDG agent dir here; "" = real search
}

# Let a test point the XDG agent dir at a sandbox (mirrors rio::agent::prompt's
# override). Covers the global + provider layers; the project layer follows the open
# project root. "" restores the real XDG-then-HOME resolution.
proc rio::agent::allow::override_dir {dir} {
	variable override_dir
	set override_dir $dir
}

# The user's agent dir — $XDG_CONFIG_HOME/rio/agent (or ~/.config/rio/agent). "" only
# if neither XDG_CONFIG_HOME nor HOME is set. Mirrors rio::agent::prompt::_userdir so
# the allow-list files sit beside system.md / providers/<name>.md.
proc rio::agent::allow::_dir {} {
	variable override_dir
	if {$override_dir ne ""} { return $override_dir }
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio agent]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio agent]
	}
	return ""
}

# Whether a provider name is safe as a filename component: non-empty, only [A-Za-z0-9_-]
# (no path separators, no `..`). Mirrors rio::agent::prompt::_safe_provider; duplicated
# to keep this module self-contained.
proc rio::agent::allow::_safe_provider {name} {
	return [expr {$name ne "" && [regexp {^[A-Za-z0-9_-]+$} $name]}]
}

# --- per-scope file resolvers (each "" when that scope has no file) -----------

# The global layer's file, or "" when there is no user dir.
proc rio::agent::allow::_global_file {} {
	set d [_dir]
	if {$d eq ""} { return "" }
	return [file join $d allow.list]
}

# A provider layer's file (`providers/<name>.allow.list` in the XDG agent dir), or ""
# when the name is empty/echo/unsafe or there is no user dir. echo is excluded — it
# ignores the tool surface, like the prompt layers exclude it.
proc rio::agent::allow::_provider_file {name} {
	if {$name eq "echo" || ![_safe_provider $name]} { return "" }
	set d [_dir]
	if {$d eq ""} { return "" }
	return [file join $d providers $name.allow.list]
}

# The project layer's file (`.rio/allow.list` at the open project root), or "" when no
# project is open.
proc rio::agent::allow::_project_file {} {
	set root [rio::project::root]
	if {$root eq ""} { return "" }
	return [file join $root .rio allow.list]
}

# Resolve a scope (+ provider name, for `provider`) to its file, or "" if unavailable.
proc rio::agent::allow::_scope_file {scope name} {
	switch -- $scope {
		global   { return [_global_file] }
		provider { return [_provider_file $name] }
		project  { return [_project_file] }
		default  { return "" }
	}
}

# --- reading -----------------------------------------------------------------

# Parse a rules file at $path: a list of rules, each a list of argv-prefix tokens.
# Reads on demand — no caching, so a hand-edit or another frontend's change is seen at
# once. Blank / `#` lines are skipped; a line that is not a well-formed Tcl list, or an
# empty rule, is skipped safely (a broken line never becomes an allow-everything rule).
# A missing file / read failure yields {}.
proc rio::agent::allow::_read {path} {
	if {$path eq "" || ![file isfile $path]} { return {} }
	if {[catch {
		set fh [open $path r]
		fconfigure $fh -encoding utf-8
		set data [read $fh]
		close $fh
	}]} { return {} }
	set out {}
	foreach line [split $data "\n"] {
		set line [string trim $line]
		if {$line eq "" || [string index $line 0] eq "#"} continue
		if {[catch {llength $line}]} continue
		if {[llength $line] == 0} continue
		lappend out $line
	}
	return $out
}

# The rules of one scope. `name` is the provider name for `provider` scope (defaulting
# to the active provider); ignored otherwise.
proc rio::agent::allow::rules {{scope global} {name ""}} {
	if {$scope eq "provider" && $name eq ""} { set name [rio::agent::provider_name] }
	return [_read [_scope_file $scope $name]]
}

# The files backing the CURRENTLY-ACTIVE scopes, in check order: global always; the
# project file when a project is open; the active provider's file when a provider runs
# (echo/unsafe excluded). Empty resolutions are dropped. This is the set `matches`
# unions over.
proc rio::agent::allow::_active_files {} {
	set files {}
	foreach f [list [_global_file] [_project_file] [_provider_file [rio::agent::provider_name]]] {
		if {$f ne ""} { lappend files $f }
	}
	return $files
}

# Is $argv trusted by ANY active layer? Prefix-checks argv against every active file's
# rules; 1 on the first hit. An empty rule never matches (it would trust everything —
# defended here as well as in `add`).
proc rio::agent::allow::matches {argv} {
	foreach f [_active_files] {
		foreach rule [_read $f] {
			set n [llength $rule]
			if {$n == 0 || $n > [llength $argv]} continue
			if {[lrange $argv 0 [expr {$n - 1}]] eq $rule} { return 1 }
		}
	}
	return 0
}

# --- writing -----------------------------------------------------------------

# Add a rule (a list of argv-prefix tokens) to one scope, persisting it. An empty rule
# is refused. An exact-equal rule already in that scope is a no-op (dedup). Creates the
# scope's dir on first write. Returns 1 on success, 0 if the rule is empty or the scope
# has no file (no user dir, no open project, or an echo/unsafe provider).
proc rio::agent::allow::add {scope name rule} {
	if {[llength $rule] == 0} { return 0 }
	if {$scope eq "provider" && $name eq ""} { set name [rio::agent::provider_name] }
	set p [_scope_file $scope $name]
	if {$p eq ""} { return 0 }
	set cur [_read $p]
	foreach r $cur { if {$r eq $rule} { return 1 } }
	lappend cur $rule
	return [_write $p $cur]
}

# Remove an exact-equal rule from one scope, persisting the result. A rule not present
# is a no-op. Returns 1 on success (or nothing to do), 0 if the scope has no file.
proc rio::agent::allow::remove {scope name rule} {
	if {$scope eq "provider" && $name eq ""} { set name [rio::agent::provider_name] }
	set p [_scope_file $scope $name]
	if {$p eq ""} { return 0 }
	set cur [_read $p]
	set out {}
	set hit 0
	foreach r $cur {
		if {$r eq $rule} { set hit 1 ; continue }
		lappend out $r
	}
	if {!$hit} { return 1 }
	return [_write $p $out]
}

# Write a rules list to $path (one rule per line, each a canonical Tcl list so it
# round-trips through `_read`). Creates the parent dir if needed. Returns 1 on success,
# 0 when the write fails.
proc rio::agent::allow::_write {path ruleslist} {
	if {$path eq ""} { return 0 }
	set lines {}
	lappend lines "# rio agent command allow-list (D84) — one rule per line, each a"
	lappend lines "# list of leading argv tokens. A command runs without the approval"
	lappend lines "# bar when its argv starts with a rule's tokens. Edit freely."
	foreach r $ruleslist { lappend lines [list {*}$r] }
	if {[catch {
		file mkdir [file dirname $path]
		set fh [open $path w]
		fconfigure $fh -encoding utf-8
		puts $fh [join $lines "\n"]
		close $fh
	}]} { return 0 }
	return 1
}
