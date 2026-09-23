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

# The same question for a PROFILE name, answered more generously (D131). A provider
# name is an identifier the user never types; a profile name is a label they choose and
# read back in a menu, so `Qwen3.8 27B (local)` has to be allowed where `openai` does
# not need to be. Spaces, dots and parentheses are fine in a filename on every host rio
# targets; what is refused is everything that could make the name mean a different FILE
# — a separator, `.` or `..`, a leading dot (hidden, and `..` adjacent), and a leading or
# trailing space (invisible, so two profiles would look identically named).
#
# `_safe` itself is deliberately NOT relaxed: it guards provider names and settings keys,
# where an identifier is the right shape and a space would be a bug.
proc rio::agent::settings::_safe_profile {name} {
	if {$name in {"" . ..}} { return 0 }
	if {[string index $name 0] eq "."} { return 0 }
	if {[string trim $name] ne $name} { return 0 }
	return [regexp {^[A-Za-z0-9._ ()-]+$} $name]
}

# A provider's settings file, or "" when the name is unsafe or there is no user dir
# (settings then degrade to in-memory-only — the session still works, it just doesn't
# remember, which is better than refusing to run).
#
# With a `profile`, the file is that profile's instead: `<provider>/<name>.conf` beside
# the flat `<provider>.conf`, which then holds only what is NOT per-profile — in
# practice the pointer at the active one, a key the PROVIDER owns and writes like any
# other (D131 keeps the core blind to meaning even here).
proc rio::agent::settings::path {provider {profile ""}} {
	if {![_safe $provider]} { return "" }
	set d [_dir]
	if {$d eq ""} { return "" }
	if {$profile eq ""} { return [file join $d providers $provider.conf] }
	if {![_safe_profile $profile]} { return "" }
	return [file join $d providers $provider $profile.conf]
}

# The directory a provider's profiles live in ("" when there is no user dir). Also the
# home for any per-profile file a provider keeps beside them — the OpenAI face's
# extra-request-JSON files sit here, which is why this is public.
proc rio::agent::settings::profile_dir {provider} {
	if {![_safe $provider]} { return "" }
	set d [_dir]
	if {$d eq ""} { return "" }
	return [file join $d providers $provider]
}

# A provider's stored settings as a {key value ...} dict; empty when there is no file.
# A malformed file is NOT fatal: a hand-edited typo must not stop the agent from
# starting, so the line error is swallowed and the defaults stand (the file is still
# there, and the user's next write rewrites it correctly).
proc rio::agent::settings::load {provider {profile ""}} {
	return [_load_file [path $provider $profile]]
}

# The parse behind `load`, for a file at `p` ("" = nowhere).
proc rio::agent::settings::_load_file {p} {
	if {$p eq "" || ![file isfile $p]} { return [dict create] }
	if {[catch {rio::conf::read_file $p} conf]} { return [dict create] }
	# Top-level keys only — a provider's settings are one flat block, so anything
	# under a [section] header is ignored rather than silently flattened.
	if {![dict exists $conf ""]} { return [dict create] }
	return [dict get $conf ""]
}

# One stored value, or $default when unset.
proc rio::agent::settings::get {provider key {default ""} {profile ""}} {
	set d [load $provider $profile]
	return [expr {[dict exists $d $key] ? [dict get $d $key] : $default}]
}

# Merge one key into the file and rewrite it. A key must be a bare word and a value
# must be one line — the format has no quoting or continuation, so a newline would
# silently produce a different file than the one asked for (D21: no quiet corruption).
proc rio::agent::settings::store {provider key value {profile ""}} {
	set head "# rio — settings for the `$provider` agent provider."
	if {$profile ne ""} { append head " Profile: $profile." }
	return [_store_file [path $provider $profile] $head $key $value]
}

# --- profiles (D131) ---------------------------------------------------------
#
# A profile is a named settings FILE, and that is the whole of what this module knows
# about one. Which keys it carries, which is active, and what any of them mean stay the
# provider's business — the same split D106 drew for the settings themselves, so these
# primitives serve a provider that keeps a model and an endpoint exactly as well as one
# that keeps something rio has never heard of.

# Every profile a provider has, sorted; {} when it has none (and when the name is
# unsafe or there is no user dir — a provider with nowhere to persist simply has no
# profiles, which is a state its caller already handles).
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

# Create a profile. `from` copies that profile's settings (Duplicate); without it the
# new file is empty, which the provider reads as "every key at its shipped default".
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

# The path a profile MUST already have, or a bad_request naming it. Every verb above
# starts here rather than failing later on a file operation, so "no such profile" reads
# the same whichever one you asked for.
proc rio::agent::settings::_existing {provider name} {
	set p [path $provider $name]
	if {$p eq "" || ![file isfile $p]} {
		rio::error::raise bad_request "no such profile: $name"
	}
	return $p
}

# The path a profile may be written to — the name has to be usable and there has to be
# somewhere to put it. Refusing the name and having no user dir are different faults and
# say so: one the user can fix by typing something else, the other they cannot.
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
