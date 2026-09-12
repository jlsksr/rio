# rio-core — a provider's own durable settings (AGENTS.md D106, D21/D24).
#
# Where a provider's runtime CHOICES live between runs: which model it talks to,
# how much effort it asks for, whatever else that provider declares as an option.
# One file per provider, in the user's agent dir beside its prompt layer and its
# allow-list:
#
#     $XDG_CONFIG_HOME/rio/agent/providers/<name>.conf
#
# in the flat `key = value` format rio already PARSES AND NEVER EXECUTES (D21's
# footgun-removal, D24's format). So a choice made from the GUI is a line a user
# can read, edit or delete with any editor — the D105 rule applied to settings:
# nothing the agent runs on should be visible only from inside rio.
#
# The split with the provider: the CORE owns the format and the location, the
# PROVIDER owns which keys exist and what they mean. Exactly the split rio::secret
# (D21) already has with the same providers' API keys — and the reason the core
# never learns the word "model" or "effort" (D106).
#
# Pure: no Tk, no protocol, no network — tests headless.

namespace eval rio::agent::settings {
	variable override_dir ""   ;# tests pin the agent dir here
}

# Let a test point the agent dir at a sandbox (mirrors rio::agent::allow::override_dir).
# "" restores the real XDG-then-HOME resolution.
proc rio::agent::settings::override_dir {dir} {
	variable override_dir
	set override_dir $dir
}

# The user's agent dir — $XDG_CONFIG_HOME/rio/agent (or ~/.config/rio/agent). "" only
# if neither XDG_CONFIG_HOME nor HOME is set. Mirrors rio::agent::allow::_dir so these
# files sit beside system.md / providers/<name>.md / allow.list.
proc rio::agent::settings::_dir {} {
	variable override_dir
	if {$override_dir ne ""} { return $override_dir }
	if {[info exists ::env(XDG_CONFIG_HOME)] && $::env(XDG_CONFIG_HOME) ne ""} {
		return [file join $::env(XDG_CONFIG_HOME) rio agent]
	} elseif {[info exists ::env(HOME)]} {
		return [file join $::env(HOME) .config rio agent]
	}
	return ""
}

# Whether a name is safe as a filename component: non-empty, only [A-Za-z0-9_-] (no
# path separators, no `..`). Mirrors the same guard in agent-prompt/agent-allow;
# duplicated to keep this module self-contained.
proc rio::agent::settings::_safe {name} {
	return [expr {$name ne "" && [regexp {^[A-Za-z0-9_-]+$} $name]}]
}

# A provider's settings file, or "" when the name is unsafe or there is no user dir
# (settings then degrade to in-memory-only — the session still works, it just doesn't
# remember, which is better than refusing to run).
proc rio::agent::settings::path {provider} {
	if {![_safe $provider]} { return "" }
	set d [_dir]
	if {$d eq ""} { return "" }
	return [file join $d providers $provider.conf]
}

# A provider's stored settings as a {key value ...} dict; empty when there is no file.
# A malformed file is NOT fatal: a hand-edited typo must not stop the agent from
# starting, so the line error is swallowed and the defaults stand (the file is still
# there, and the user's next write rewrites it correctly).
proc rio::agent::settings::load {provider} {
	set p [path $provider]
	if {$p eq "" || ![file isfile $p]} { return [dict create] }
	if {[catch {rio::conf::read_file $p} conf]} { return [dict create] }
	# Top-level keys only — a provider's settings are one flat block, so anything
	# under a [section] header is ignored rather than silently flattened.
	if {![dict exists $conf ""]} { return [dict create] }
	return [dict get $conf ""]
}

# One stored value, or $default when unset.
proc rio::agent::settings::get {provider key {default ""}} {
	set d [load $provider]
	return [expr {[dict exists $d $key] ? [dict get $d $key] : $default}]
}

# Merge one key into the file and rewrite it. A key must be a bare word and a value
# must be one line — the format has no quoting or continuation, so a newline would
# silently produce a different file than the one asked for (D21: no quiet corruption).
proc rio::agent::settings::store {provider key value} {
	if {![_safe $key]} {
		rio::error::raise bad_request "settings key must be \[A-Za-z0-9_-\]+: $key"
	}
	if {[string first "\n" $value] >= 0} {
		rio::error::raise bad_request "settings value must be a single line"
	}
	set p [path $provider]
	if {$p eq ""} { return "" }   ;# nowhere to persist — the live value still stands
	set d [load $provider]
	dict set d $key $value
	file mkdir [file dirname $p]
	set fh [open $p w 0600]
	fconfigure $fh -encoding utf-8
	puts $fh "# rio — settings for the `$provider` agent provider."
	puts $fh "# Written by rio and hand-editable: one `key = value` per line."
	foreach k [lsort [dict keys $d]] { puts $fh "$k = [dict get $d $k]" }
	close $fh
	return $p
}
