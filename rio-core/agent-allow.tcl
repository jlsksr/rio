# rio-core — the agent's command allow-list (D84).
#
# run_command always waits for the user (D83). A rule the user wrote lets a
# trusted command run without asking. Only the confirmation is skipped:
# prepare_exec's guards still apply.
#
# A rule is an argv prefix, compared token by token. No shell, no globbing.
#
#   rule {pytest}       allows  pytest, pytest -q tests/
#   rule {git status}   allows  git status, git status -s    not  git push
#
# Three scopes, as for the prompt layers (D70, D79):
#
#   global    <xdg>/allow.list                    always
#   provider  <xdg>/providers/<name>.allow.list   while that provider runs; not echo
#   project   <root>/.rio/allow.list              while that project is open
#
#   <xdg> is $XDG_CONFIG_HOME/rio/agent.
#
# A file holds one rule per line, a Tcl list; blank and `#` lines are ignored.
# A command is trusted if any active scope allows it.

namespace eval rio::agent::allow {
	variable override_dir ""   ;# tests pin the XDG agent dir here; "" = real search
}

# Let a test point the agent dir at a sandbox (global and provider scopes).
# "" restores the real one.
proc rio::agent::allow::override_dir {dir} {
	variable override_dir
	set override_dir $dir
}

# The user's agent dir: $XDG_CONFIG_HOME/rio/agent, or ~/.config/rio/agent.
# "" if neither variable is set.
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

# Is a provider name safe in a filename? Only [A-Za-z0-9_-].
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

# A provider scope's file, or "" (echo, an unsafe name, no user dir).
proc rio::agent::allow::_provider_file {name} {
	if {$name eq "echo" || ![_safe_provider $name]} { return "" }
	set d [_dir]
	if {$d eq ""} { return "" }
	return [file join $d providers $name.allow.list]
}

# The project scope's file, or "" when no project is open.
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

# The rules in the file at $path. Read on every call, so a hand edit counts
# at once. A line that is not a Tcl list, or is an empty rule, is skipped: a
# broken line must never allow everything. A missing file gives {}.
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

# The files of the scopes active now: global, the open project's, the active
# provider's.
proc rio::agent::allow::_active_files {} {
	set files {}
	foreach f [list [_global_file] [_project_file] [_provider_file [rio::agent::provider_name]]] {
		if {$f ne ""} { lappend files $f }
	}
	return $files
}

# Does any active scope allow $argv? An empty rule never matches.
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

# Add a rule to one scope and write the file. A rule already there is a
# no-op. Returns 1 on success, 0 if the rule is empty or the scope has no file.
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

# Remove a rule from one scope and write the file. A rule not there is a
# no-op. Returns 1 on success, 0 if the scope has no file.
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

# Write a rules list to $path, one canonical Tcl list per line. Returns 1 on
# success, 0 when the write fails.
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
