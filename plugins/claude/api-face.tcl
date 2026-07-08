# plugins/claude — the claude-api face (AGENTS.md D26).
#
# The official, supported Claude provider: it authenticates with an Anthropic
# API key (pay-per-token) and drives the shared inference core (rio::claude::infer).
# This is the only sanctioned, stable, ToS-compliant path for a third-party
# integration, so it is the path rio ships. The face owns ONLY its auth strategy
# (the `x-api-key` header), a config block, and the key's storage; the durable
# inference code is shared, leaving room for other auth strategies later without a
# rewrite.
#
# Resilience (D26): every volatile detail — endpoint, model, API version, and the
# request-timeout budget — lives in `config` as DATA, overridable at runtime, so an
# upstream change is a one-line edit, not a rebuild. Failures surface as classified
# agent.error events (from the inference core) with an actionable next step.
#
# Network is a SEAM (transport), so the whole flow is testable offline; the real
# tcltls transport (transport.tcl) is the default.

package require json

namespace eval rio::claude::api {
	# Config-as-data: the documented Anthropic Messages API. No beta header is sent
	# — this is the plain, supported request. The `system` prompt is not a static
	# config key: the core composes it per turn and the provider merges it in (D34).
	variable config [dict create \
		messages_url      https://api.anthropic.com/v1/messages \
		anthropic_version 2023-06-01 \
		model             claude-sonnet-5 \
		max_tokens        4096 \
		request_timeout   600000 \
		secret_name       claude-api]

	# Network seam: the real tcltls streaming transport (transport.tcl); tests
	# inject a fake.
	variable transport rio::claude::http::stream
}

# Override one config key (a user setting, a test, or a model choice).
proc rio::claude::api::configure {key val} {
	variable config
	dict set config $key $val
}
proc rio::claude::api::cget {key} {
	variable config
	return [dict get $config $key]
}

# --- the provider (agent contract: conversation tools system post) -----------
proc rio::claude::api::provider {conversation tools system post} {
	variable config
	variable transport
	set key [_api_key]
	if {$key eq ""} {
		{*}$post error not_configured \
			"No Claude API key — add one in Settings ▸ Claude API key"
		return
	}
	set auth [list x-api-key $key]
	# The core owns the system prompt (D34); merge it into a LOCAL config copy so
	# the persistent config dict stays clean. infer skips an empty `system`.
	set conf $config
	dict set conf system $system
	rio::claude::infer $conf $conversation $tools $auth $transport $post
}

# Whether a key is stored (the GUI offers Set / Clear accordingly).
proc rio::claude::api::configured {} {
	variable config
	return [rio::secret::has [dict get $config secret_name]]
}

# Store / replace the API key (a 0600 secret, apart from settings; D21).
proc rio::claude::api::set_key {key} {
	variable config
	rio::secret::save [dict get $config secret_name] [dict create api_key $key]
}

proc rio::claude::api::clear_key {} {
	variable config
	rio::secret::forget [dict get $config secret_name]
}

# The stored API key, or "" if none is set.
proc rio::claude::api::_api_key {} {
	variable config
	set s [rio::secret::get [dict get $config secret_name]]
	return [expr {[dict exists $s api_key] ? [dict get $s api_key] : ""}]
}

# Register with the agent's named-provider registry (D26/D30) so a frontend can
# select this face by name over the channel (agent.provider.set claude). The key
# capability routes agent.key.set/clear/status here — the API key is this face's to
# keep (D21), the agent layer stays credential-blind.
rio::agent::register_provider claude rio::claude::api::provider \
	-key [dict create \
		set    rio::claude::api::set_key \
		clear  rio::claude::api::clear_key \
		status rio::claude::api::configured]
