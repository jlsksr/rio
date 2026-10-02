# rio-core — a provider's own durable settings (D106, D21/D24).
#
# Where a provider's choices (its model, its effort, …) live between runs:
#
#     $XDG_CONFIG_HOME/rio/agent/providers/<name>.conf             flat settings
#     $XDG_CONFIG_HOME/rio/agent/providers/<name>/<profile>.conf   one per profile (D131)
#
# Flat `key = value`, parsed and never executed (D21, D24), so a user can read
# and edit it. The core owns format and location; the provider owns the keys
# and what they mean (D106).
#
# No Tk, no protocol, no network.

namespace eval rio::agent::settings {
	variable override_dir ""   ;# tests pin the agent dir here
}

# Let a test point the agent dir at a sandbox. "" restores the real one.
proc rio::agent::settings::override_dir {dir} {
	variable override_dir
	set override_dir $dir
}

# The user's agent dir: $XDG_CONFIG_HOME/rio/agent, or ~/.config/rio/agent.
# "" if neither variable is set.
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

# Is a provider name or a settings key safe in a filename? Only [A-Za-z0-9_-].
proc rio::agent::settings::_safe {name} {
	return [expr {$name ne "" && [regexp {^[A-Za-z0-9_-]+$} $name]}]
}

# The same for a profile name (D131). A profile name is a label the user
# chooses, so spaces, dots and parentheses are allowed: `Qwen3.8 27B (local)`.
# Refused: a separator, `.`, `..`, a leading dot, a leading or trailing space.
proc rio::agent::settings::_safe_profile {name} {
	if {$name in {"" . ..}} { return 0 }
	if {[string index $name 0] eq "."} { return 0 }
	if {[string trim $name] ne $name} { return 0 }
	return [regexp {^[A-Za-z0-9._ ()-]+$} $name]
}

# A provider's settings file, or with `profile` that profile's file. "" when
# a name is unsafe or there is no user dir; settings then live in memory only.
proc rio::agent::settings::path {provider {profile ""}} {
	if {![_safe $provider]} { return "" }
	set d [_dir]
	if {$d eq ""} { return "" }
	if {$profile eq ""} { return [file join $d providers $provider.conf] }
	if {![_safe_profile $profile]} { return "" }
	return [file join $d providers $provider $profile.conf]
}

# The directory a provider's profiles live in, or "". Public: a provider may
# keep its own per-profile files there.
proc rio::agent::settings::profile_dir {provider} {
	if {![_safe $provider]} { return "" }
	set d [_dir]
	if {$d eq ""} { return "" }
	return [file join $d providers $provider]
}

# A provider's stored settings as a {key value ...} dict. No file, or a
# malformed one, gives an empty dict: a typo must not stop the agent.
proc rio::agent::settings::load {provider {profile ""}} {
	return [_load_file [path $provider $profile]]
}

# The parse behind `load`, for a file at `p` ("" = nowhere).
proc rio::agent::settings::_load_file {p} {
	if {$p eq "" || ![file isfile $p]} { return [dict create] }
	if {[catch {rio::conf::read_file $p} conf]} { return [dict create] }
	# Top-level keys only; anything under a [section] is ignored.
	if {![dict exists $conf ""]} { return [dict create] }
	return [dict get $conf ""]
}

# One stored value, or $default when unset.
proc rio::agent::settings::get {provider key {default ""} {profile ""}} {
	set d [load $provider $profile]
	return [expr {[dict exists $d $key] ? [dict get $d $key] : $default}]
}

# Merge one key into the file and rewrite it. The key is a bare word, the
# value one line: the format has no quoting.
proc rio::agent::settings::store {provider key value {profile ""}} {
	set head "# rio — settings for the `$provider` agent provider."
	if {$profile ne ""} { append head " Profile: $profile." }
	return [_store_file [path $provider $profile] $head $key $value]
}

# --- profiles (D131) ---------------------------------------------------------
#
# A profile is a named settings file. Its keys, and which profile is active,
# are the provider's business.

# Every profile a provider has, sorted; {} for none.
proc rio::agent::settings::profiles {provider} {
	set d [profile_dir $provider]
	if {$d eq "" || ![file isdirectory $d]} { return {} }
	set out {}
	foreach f [glob -nocomplain -directory $d -tails -- *.conf] {
		set n [file rootname $f]
		if {[_safe_profile $n]} { lappend out $n }
	}
	return [lsort $out]
}

proc rio::agent::settings::profile_exists {provider name} {
	set p [path $provider $name]
	return [expr {$p ne "" && [file isfile $p]}]
}

# Create a profile: a copy of `from`, or an empty file, which means defaults.
proc rio::agent::settings::profile_add {provider name {from ""}} {
	set p [_writable $provider $name]
	if {[file isfile $p]} {
		rio::error::raise bad_request "a profile named '$name' already exists"
	}
	file mkdir [file dirname $p]
	if {$from ne ""} {
		file copy -- [_existing $provider $from] $p
	} else {
		close [open $p w 0600]
	}
	return $name
}

proc rio::agent::settings::profile_rename {provider name to} {
	set src [_existing $provider $name]
	set dst [_writable $provider $to]
	if {$name eq $to} { return $to }
	if {[file isfile $dst]} {
		rio::error::raise bad_request "a profile named '$to' already exists"
	}
	file rename -- $src $dst
	return $to
}

proc rio::agent::settings::profile_remove {provider name} {
	file delete -- [_existing $provider $name]
	return $name
}

# The path of an existing profile, or a bad_request.
proc rio::agent::settings::_existing {provider name} {
	set p [path $provider $name]
	if {$p eq "" || ![file isfile $p]} {
		rio::error::raise bad_request "no such profile: $name"
	}
	return $p
}

# The path a profile may be written to. A bad name is a bad_request; no user
# dir is an io_error.
proc rio::agent::settings::_writable {provider name} {
	if {![_safe_profile $name]} {
		rio::error::raise bad_request \
			"a profile name may use letters, digits, spaces and . _ - ( ) — not '$name'"
	}
	set p [path $provider $name]
	if {$p eq ""} {
		rio::error::raise io_error "nowhere to store profiles for '$provider'"
	}
	return $p
}

# The validated rewrite behind `store`: merge key into the file at `p`
# ("" = nowhere to persist, returns "") under a one-line `header` comment.
proc rio::agent::settings::_store_file {p header key value} {
	if {![_safe $key]} {
		rio::error::raise bad_request "settings key must be \[A-Za-z0-9_-\]+: $key"
	}
	if {[string first "\n" $value] >= 0} {
		rio::error::raise bad_request "settings value must be a single line"
	}
	if {$p eq ""} { return "" }   ;# nowhere to persist — the live value still stands
	set d [_load_file $p]
	dict set d $key $value
	file mkdir [file dirname $p]
	set fh [open $p w 0600]
	fconfigure $fh -encoding utf-8
	puts $fh $header
	puts $fh "# Written by rio and hand-editable: one `key = value` per line."
	foreach k [lsort [dict keys $d]] { puts $fh "$k = [dict get $d $k]" }
	close $fh
	return $p
}
