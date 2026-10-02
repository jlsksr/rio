# rio-core — the provider.* op namespace (D66, D39, D11).
#
# The provider store's ops (rio::provider). The Extensions window installs a
# provider through them, onto the core's disk (D30).
#
#   provider.list     what is on disk, activated or not
#   agent.providers   what is registered and live in this run (D65)

# provider.list {} -> {providers:[{name, version, source, api, loadable}], api_max}
#   api_max  — the highest provider-api this core implements
#   loadable — can this core source it? A loadable provider that is not
#              registered waits for the next core start.
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
# Install or replace a provider. `files` is an object filename -> content.
# Manifest and names are validated before anything is written. The code is
# not sourced: it activates on the next core start.
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
