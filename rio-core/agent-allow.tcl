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
# Persisted GLOBALLY like the per-provider prompts (D79): a plain `allow.list` in the
# XDG agent dir, one rule per line, each line a Tcl list; `#` lines and blanks are
# ignored, so it stays hand-editable. Applies across every project.

namespace eval rio::agent::allow {
	variable override_dir ""   ;# tests pin the agent dir here; "" = real XDG search
}

# Let a test point the allow-list at a sandbox dir (mirrors rio::agent::prompt's
# override). "" restores the real XDG-then-HOME resolution.
proc rio::agent::allow::override_dir {dir} {
	variable override_dir
	set override_dir $dir
}

# The user's agent dir — where `allow.list` lives: $XDG_CONFIG_HOME/rio/agent (or
# ~/.config/rio/agent). "" only if neither XDG_CONFIG_HOME nor HOME is set. Mirrors
# rio::agent::prompt::_userdir so the allow-list sits beside system.md / providers/.
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

# The allow.list path, or "" when there is no user dir.
proc rio::agent::allow::_file {} {
	set d [_dir]
	if {$d eq ""} { return "" }
	return [file join $d allow.list]
}

# The current rules: a list of rules, each rule a list of argv-prefix tokens. Reads
# the (tiny) file on demand — no caching, so a hand-edit or another frontend's change
# is seen immediately. Blank and `#` comment lines are skipped; a line that is not a
# well-formed Tcl list, or an empty rule, is skipped safely (a broken line never
# becomes an allow-everything rule). A missing file / read failure yields {}.
proc rio::agent::allow::rules {} {
	set p [_file]
	if {$p eq "" || ![file isfile $p]} { return {} }
	if {[catch {
		set fh [open $p r]
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

# Does any rule's tokens form a prefix of $argv? An empty rule never matches (it would
# trust everything — defended here as well as in `add`). Program-name rule = a
# one-token prefix; exact rule = a full-argv prefix.
proc rio::agent::allow::matches {argv} {
	foreach rule [rules] {
		set n [llength $rule]
		if {$n == 0 || $n > [llength $argv]} continue
		if {[lrange $argv 0 [expr {$n - 1}]] eq $rule} { return 1 }
	}
	return 0
}

# Add a rule (a list of argv-prefix tokens), persisting it. An empty rule is refused.
# An exact-equal rule already present is a no-op (dedup). Creates the agent dir on
# first write. Returns 1 on success, 0 if the rule is empty or there is no user dir.
proc rio::agent::allow::add {rule} {
	if {[llength $rule] == 0} { return 0 }
	set cur [rules]
	foreach r $cur { if {$r eq $rule} { return 1 } }
	lappend cur $rule
	return [_write $cur]
}

# Remove an exact-equal rule, persisting the result. A rule that is not present is a
# no-op. Returns 1 on success (or nothing to do), 0 if there is no user dir.
proc rio::agent::allow::remove {rule} {
	set cur [rules]
	set out {}
	set hit 0
	foreach r $cur {
		if {$r eq $rule} { set hit 1 ; continue }
		lappend out $r
	}
	if {!$hit} { return 1 }
	return [_write $out]
}

# Write the rules list back to allow.list (one rule per line, each a canonical Tcl
# list so it round-trips through `rules`). Creates the agent dir if needed. Returns 1
# on success, 0 when there is no user dir or the write fails.
proc rio::agent::allow::_write {ruleslist} {
	set p [_file]
	if {$p eq ""} { return 0 }
	set lines {}
	lappend lines "# rio agent command allow-list (D84) — one rule per line, each a"
	lappend lines "# list of leading argv tokens. A command runs without the approval"
	lappend lines "# bar when its argv starts with a rule's tokens. Edit freely."
	foreach r $ruleslist { lappend lines [list {*}$r] }
	if {[catch {
		file mkdir [file dirname $p]
		set fh [open $p w]
		fconfigure $fh -encoding utf-8
		puts $fh [join $lines "\n"]
		close $fh
	}]} { return 0 }
	return 1
}
