# rio-core — the installable-provider store + loader (AGENTS.md D66, D39, D30).
#
# An agent provider (D26/D65) is executable Tcl that runs in the CORE process and
# can be handed the user's API key (D21) to make network calls with it. Milestone B
# makes `provider` an installable D39 `kind`: a publisher ships a provider in a
# repository like any other extension, and the GUI installs it CORE-side (a remote
# core stores on ITS disk, D30) into this store. Unlike syntax/mode (GUI-side
# drop-ins) and theme (data), a provider is SOURCED into the core — so it is gated
# by a VERSIONED contract (provider-api) and activates only on the next core start
# (restart-to-activate: no sourcing of remote Tcl into a long-lived, possibly
# shared, already-running core).
#
# The provider-api this core implements — the surface a `provider-api = N` manifest
# promises against — is loaded BEFORE any provider is sourced (server.tcl):
#   1 - rio::agent::register_provider (with -label / -signup / -key),
#     - the provider proc contract {conversation tools system post} and the `post`
#       vocab delta / tool / done ?stop_reason? / error (rio::agent, D65),
#     - the runtime helpers rio::llm::http::stream, rio::llm::jstr / rio::llm::obj_json
#       (plugins/lib) and rio::secret::* (the 0600 key store, D21).
#   2 - register_provider's -options capability {list set ?refresh?} and the
#       agent.option* ops behind it (D106),
#     - rio::agent::settings::* (the provider's own durable choices, one flat
#       hand-editable file per provider),
#     - the runtime helper rio::llm::http::get (a plain GET, for a models listing).
#   3 - the runtime helper rio::llm::jascii: \u-escapes every non-ASCII character of
#       an already-valid JSON document, for the parts of a body a provider splices in
#       ALREADY SERIALISED (a tool's input_schema, a captured tool_use input) and that
#       therefore never went through jstr.
#   4 - an option descriptor's rendering vocabulary — `kind` (choice | text | number),
#       `group` and `quick` (rio::agent::_option_norm) — so a provider can declare a
#       setting that is a FIELD rather than a menu of choices, and say where it belongs,
#       - the `post thinking <text>` verb: reasoning that is shown but never recorded in
#         the conversation, so it is not re-sent or re-billed on a later step.
#   5 - register_provider's -profiles capability {list switch add remove rename} and the
#       agent.profile* ops behind it: SEVERAL named configurations of everything the
#       provider keeps, one active (D131),
#     - rio::agent::settings' profile-scoped storage — `path` / `get` / `store` take a
#       profile, and profiles / profile_dir / profile_add / profile_rename /
#       profile_remove manage the files,
#     - an option descriptor's `file` flag and the agent.option.file op behind it: the
#       value names a file the provider resolves and creates, which a frontend opens in
#       the editor.
# A provider declaring an OLDER api still loads: the surface only grows. Every level
# belongs HERE, beside the ceiling it raises — a level documented only in CONTRIBUTING
# is one the file that owns the number does not admit to implementing.
#
# The store is one dir per provider: <name>/rio-extension.conf (the D39 manifest,
# parsed as conf — data, never executed — to decide WHETHER to source) plus its
# payload .tcl files. Only a version-supported provider's `entry` file is sourced.
# Pure module: no Tk.

namespace eval rio::provider {
	variable override_dir ""   ;# tests point this at a temp dir; "" = real XDG path
	variable api_version 5     ;# the highest provider-api this core implements
}

# The highest provider-api this core implements — a frontend compares a repo
# provider's declared provider-api against it (provider.list `api_max`).
proc rio::provider::supported_api {} {
	variable api_version
	return $api_version
}

# The provider store: $XDG_DATA_HOME/rio/providers (default ~/.local/share/...),
# per D21's data-dir locations — installed executable software, alongside secrets,
# not the hand-edited config dir.
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

# D39's safe-name rule, applied to every store-side name (provider dir, entry file,
# each payload) before any path join — traversal and percent-encoding die here.
proc rio::provider::valid_name {name} {
	return [regexp {^[A-Za-z0-9][A-Za-z0-9._-]*$} $name]
}

# Every provider on disk in the store, newest-safe: a list of dicts
# {name version source entry files api loadable}. `api` is the manifest's
# provider-api (a string, "" if undeclared); `loadable` is 1 iff this core can
# source it (kind=provider, a supported provider-api, a safe entry file present).
# A store dir whose manifest is missing/unparseable/not-a-provider is skipped
# silently — the store holds only what an install wrote, but stays robust to junk.
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

# Source every loadable installed provider (called ONCE at core startup, AFTER the
# built-in providers register and AFTER the provider-api runtime is present). A
# provider whose provider-api this core can't support is skipped (it still LISTS —
# provider.list reports loadable=0 — never loads, D39's "too-new lists, doesn't
# install"). A broken payload is logged and skipped: one bad installed provider
# must never take the core down.
proc rio::provider::load_all {} {
	foreach p [installed] {
		if {![dict get $p loadable]} continue
		set path [file join [_dir] [dict get $p name] [dict get $p entry]]
		if {[catch {uplevel #0 [list source $path]} err]} {
			catch {puts stderr "rio-core: installed provider [dict get $p name] failed to load: $err"}
		}
	}
}

# Install/replace a provider in the store (D39, CORE-side — the GUI fetched the
# payloads and calls this so a remote core stores on its own disk). `manifest` is
# the raw rio-extension.conf text; `files` a dict filename->content of the payload
# .tcl files; `source` (optional) the repository base, recorded for provenance.
# Refuses up front what this core could never load — bad name, a payload filename
# that isn't safe, a non-provider manifest, or a provider-api past this core — so
# the store never holds a dead install. All-or-nothing: the dir is written fresh.
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
	# Provenance rides along in the stored manifest (the remote conf never carries a
	# source; provider.list then reports where an installed provider came from).
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

# Remove an installed provider from the store. It stays live until the core next
# restarts (the running core already sourced it — symmetry with activate-on-restart).
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
