# rio-core — the installable-provider store + loader (D66, D39, D30).
#
# A provider is Tcl that runs in the core and may be handed the user's API key
# (D21). It installs from a repository like any extension (D39), into the
# core's own disk (D30). Because it is sourced into the core:
# - a versioned contract, provider-api, gates it;
# - it activates on the next core start, never in a running core.
#
# The store: one dir per provider.
#
#   <store>/<name>/rio-extension.conf   the manifest: parsed, never executed
#   <store>/<name>/*.tcl                the payload; only `entry` is sourced
#
# What each provider-api level added. An older provider still loads: the
# surface only grows. A new level is recorded here, beside `api_version`.
#
#   1  rio::agent::register_provider (-label, -signup, -key)
#      the provider proc {conversation tools system post}; `post` verbs
#        delta, tool, done ?stop_reason?, error (D65)
#      rio::llm::http::stream, rio::llm::jstr, rio::llm::obj_json
#      rio::secret::* (D21)
#   2  register_provider -options {list set ?refresh?}; agent.option* (D106)
#      rio::agent::settings::*: a provider's own stored choices
#      rio::llm::http::get
#   3  rio::llm::jascii: \u-escapes non-ASCII in JSON a provider splices in
#        already serialised
#   4  option descriptor keys `kind` (choice | text | number), `group`, `quick`
#      `post thinking <text>`: shown, never recorded in the conversation
#   5  register_provider -profiles {list switch add remove rename};
#        agent.profile* (D131)
#      rio::agent::settings takes a profile; profiles, profile_dir,
#        profile_add, profile_rename, profile_remove
#      option descriptor key `file`; agent.option.file
#
# No Tk.

namespace eval rio::provider {
	variable override_dir ""   ;# tests point this at a temp dir; "" = real XDG path
	variable api_version 5     ;# the highest provider-api this core implements
}

# The highest provider-api this core implements (provider.list `api_max`).
proc rio::provider::supported_api {} {
	variable api_version
	return $api_version
}

# The store: $XDG_DATA_HOME/rio/providers, default ~/.local/share/. The data
# dir, not the config dir: this is installed software (D21).
proc rio::provider::_dir {} {
	variable override_dir
	if {$override_dir ne ""} { return $override_dir }
	if {[info exists ::env(XDG_DATA_HOME)] && $::env(XDG_DATA_HOME) ne ""} {
		set base $::env(XDG_DATA_HOME)
	} elseif {[info exists ::env(HOME)]} {
		set base [file join $::env(HOME) .local share]
	} else {
		set base [pwd]
	}
	return [file join $base rio providers]
}

# D39's safe-name rule. Every name (provider dir, entry, payload) passes it
# before a path join, so no traversal.
proc rio::provider::valid_name {name} {
	return [regexp {^[A-Za-z0-9][A-Za-z0-9._-]*$} $name]
}

# Every provider in the store, as {name version source entry files api
# loadable} dicts. `api` is the manifest's provider-api, "" if undeclared.
# `loadable` is 1 if this core can source it: a supported api and a safe entry
# file that exists. A dir without a usable provider manifest is skipped.
proc rio::provider::installed {} {
	variable api_version
	set out {}
	set dir [_dir]
	foreach sub [lsort [glob -nocomplain -type d -directory $dir *]] {
		set name [file tail $sub]
		if {![valid_name $name]} continue
		set mf [file join $sub rio-extension.conf]
		if {![file isfile $mf]} continue
		if {[catch {rio::conf::read_file $mf} conf]} continue
		set top [expr {[dict exists $conf ""] ? [dict get $conf ""] : {}}]
		if {![dict exists $top kind] || [dict get $top kind] ne "provider"} continue
		set version [expr {[dict exists $top version] ? [dict get $top version] : "?"}]
		set source  [expr {[dict exists $top source]  ? [dict get $top source]  : ""}]
		set entry   [expr {[dict exists $top entry]   ? [dict get $top entry]   : ""}]
		set api     [expr {[dict exists $top provider-api] ? [dict get $top provider-api] : ""}]
		set files {}
		if {[dict exists $top files]} {
			foreach f [split [dict get $top files]] { if {$f ne ""} { lappend files $f } }
		}
		set loadable [expr {
			[string is integer -strict $api] && $api >= 1 && $api <= $api_version
			&& [valid_name $entry] && [file isfile [file join $sub $entry]]
		}]
		lappend out [dict create \
			name $name version $version source $source entry $entry \
			files $files api $api loadable [expr {$loadable ? 1 : 0}]]
	}
	return $out
}

# Source every loadable provider. Called once at core start, after the
# built-ins and the provider-api runtime are in place. A broken payload is
# logged and skipped: it must not take the core down.
proc rio::provider::load_all {} {
	foreach p [installed] {
		if {![dict get $p loadable]} continue
		set path [file join [_dir] [dict get $p name] [dict get $p entry]]
		if {[catch {uplevel #0 [list source $path]} err]} {
			catch {puts stderr "rio-core: installed provider [dict get $p name] failed to load: $err"}
		}
	}
}

# Install or replace a provider (D39). The GUI fetched the payloads; the core
# stores them on its own disk.
#   manifest — the rio-extension.conf text
#   files    — dict filename -> content
#   source   — the repository base, recorded in the stored manifest
# Refuses what this core could never load, so the store holds no dead install.
# All or nothing: the dir is written fresh.
proc rio::provider::put {name manifest files {source ""}} {
	variable api_version
	if {![valid_name $name]} {
		rio::error::raise bad_request "bad provider name: $name"
	}
	if {[catch {rio::conf::parse $manifest} conf]} {
		rio::error::raise bad_request "provider $name: unparseable manifest"
	}
	set top [expr {[dict exists $conf ""] ? [dict get $conf ""] : {}}]
	if {![dict exists $top kind] || [dict get $top kind] ne "provider"} {
		rio::error::raise bad_request "provider $name: manifest kind is not 'provider'"
	}
	set api [expr {[dict exists $top provider-api] ? [dict get $top provider-api] : ""}]
	if {![string is integer -strict $api] || $api < 1} {
		rio::error::raise bad_request "provider $name: manifest declares no usable provider-api"
	}
	if {$api > $api_version} {
		rio::error::raise bad_request \
			"provider $name needs a newer rio (provider-api $api > $api_version)"
	}
	set entry [expr {[dict exists $top entry] ? [dict get $top entry] : ""}]
	if {![valid_name $entry]} {
		rio::error::raise bad_request "provider $name: manifest names no usable entry file"
	}
	dict for {f _} $files {
		if {![valid_name $f]} {
			rio::error::raise bad_request "provider $name: unsafe payload filename: $f"
		}
	}
	if {![dict exists $files $entry]} {
		rio::error::raise bad_request "provider $name: entry file '$entry' is not among the payloads"
	}
	# Record the source, so provider.list can say where it came from.
	set stored $manifest
	if {$source ne "" && ![dict exists $top source]} {
		set stored "source = $source\n$manifest"
	}
	set dir [file join [_dir] $name]
	if {[catch {
		file delete -force $dir
		file mkdir $dir
		set mf [open [file join $dir rio-extension.conf] w]
		fconfigure $mf -encoding utf-8 ; puts -nonewline $mf $stored ; close $mf
		dict for {f text} $files {
			set out [open [file join $dir $f] w]
			fconfigure $out -encoding utf-8 ; puts -nonewline $out $text ; close $out
		}
	} err]} {
		catch {file delete -force $dir}
		rio::error::raise io_error "cannot install provider $name: $err"
	}
	return
}

# Remove a provider from the store. It stays live until the core restarts.
proc rio::provider::delete {name} {
	if {![valid_name $name]} {
		rio::error::raise bad_request "bad provider name: $name"
	}
	set dir [file join [_dir] $name]
	if {![file isdirectory $dir]} {
		rio::error::raise bad_request "no such installed provider: $name"
	}
	if {[catch {file delete -force $dir} err]} {
		rio::error::raise io_error "cannot remove provider $name: $err"
	}
	return
}
