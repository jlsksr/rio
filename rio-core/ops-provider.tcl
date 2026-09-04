# rio-core — the provider.* op namespace (AGENTS.md D66, D39, D11).
#
# The channel face of the installable-provider store (rio::provider). A frontend's
# Extensions window installs a `kind = provider` extension through these ops so the
# code lands on the CORE's disk (a remote core stores on its own, D30) and loads on
# the core's next start. Distinct from agent.providers (D65), which lists what is
# REGISTERED/live this run: provider.list is what's ON DISK, including a provider
# that is installed but not yet activated, or one too new for this core to load.

# provider.list {} -> {providers:[{name, version, source, api, loadable}], api_max}
# Every provider in the store, plus `api_max` — the highest provider-api this core
# implements, so a frontend can grey a repo provider that needs a newer rio before
# an install even reaches the core. `loadable` is whether this core can source an
# installed one; a loadable-but-unregistered provider is one awaiting the restart
# that activates it. A non-flat result — the wire layer shapes it (D25).
proc rio::ops::provider_list {params} {
	set out {}
	foreach p [rio::provider::installed] {
		lappend out [dict create \
			name     [dict get $p name] \
			version  [dict get $p version] \
			source   [dict get $p source] \
			api      [dict get $p api] \
			loadable [dict get $p loadable]]
	}
	return [dict create result [dict create \
		providers $out api_max [rio::provider::supported_api]]]
}
rio::dispatch::register provider.list rio::ops::provider_list

# provider.put {name manifest files ?source?} -> {}
# Install/replace a provider in the store. `files` is an object filename->content
# (the payload .tcl files, incl. the entry file). The core validates the manifest
# and every name before anything is written (bad_request on a name, an unparseable
# or non-provider manifest, or a provider-api past this core). It does NOT source
# the code — the provider activates on the next core start (restart-to-activate).
proc rio::ops::provider_put {params} {
	foreach k {name manifest files} {
		if {![dict exists $params $k]} {
			rio::error::raise bad_request "provider.put requires $k"
		}
	}
	set source [expr {[dict exists $params source] ? [dict get $params source] : ""}]
	rio::provider::put [dict get $params name] [dict get $params manifest] \
		[dict get $params files] $source
	return [dict create result {}]
}
rio::dispatch::register provider.put rio::ops::provider_put

# provider.delete {name} -> {}
# Uninstall a provider from the store (it stays live until the core restarts).
proc rio::ops::provider_delete {params} {
	if {![dict exists $params name]} {
		rio::error::raise bad_request "provider.delete requires name"
	}
	rio::provider::delete [dict get $params name]
	return [dict create result {}]
}
rio::dispatch::register provider.delete rio::ops::provider_delete
