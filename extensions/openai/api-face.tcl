# extensions/openai — the OpenAI-compatible API face (AGENTS.md D8, D26).
#
# An OpenAI-compatible agent provider: it authenticates with a Bearer API key and
# drives the shared inference core (rio::openai::infer). Hosted ChatGPT is the
# default endpoint, but because the endpoint is config-as-data the same face drives
# any OpenAI-compatible server — Ollama, llama-server, LM Studio, vLLM — which is
# the in-box local-LLM provider AGENTS.md D8 names. The face owns only its auth
# strategy (the `Authorization: Bearer` header), a config block, and the key's
# storage; the durable inference code is shared.
#
# Resilience (D26): every volatile detail — endpoint, model, the token-cap param
# name, the timeout budget — lives in `config` as DATA, overridable at runtime, so
# a model or server change is a one-line edit, not a rebuild. Network is a SEAM
# (the shared transport), so the whole flow is testable offline.

package require json

namespace eval rio::openai::api {
	# Config-as-data. `token_param` is the request key for the output cap: hosted
	# newer OpenAI models require `max_completion_tokens`, while older models and
	# most local OpenAI-compatible servers take `max_tokens` — switch it here for a
	# model/server that wants the other, no code change. `messages_url` points at a
	# local server (e.g. http://localhost:11434/v1/chat/completions for Ollama) to
	# use a local model. The `system` prompt is not static config: the core composes
	# it per turn and the provider merges it in (D34).
	variable config [dict create \
		messages_url    https://api.openai.com/v1/chat/completions \
		model           gpt-4o \
		token_param     max_tokens \
		max_tokens      4096 \
		request_timeout 600000 \
		secret_name     openai-api]

	# Network seam: the shared tcltls streaming transport (plugins/lib/transport.tcl);
	# tests inject a fake.
	variable transport rio::llm::http::stream
}

# Override one config key (a user setting, a test, a model or endpoint choice).
proc rio::openai::api::configure {key val} {
	variable config
	dict set config $key $val
}
proc rio::openai::api::cget {key} {
	variable config
	return [dict get $config $key]
}

# --- the provider (agent contract: conversation tools system post) -----------
proc rio::openai::api::provider {conversation tools system post} {
	variable config
	variable transport
	set key [_api_key]
	if {$key eq ""} {
		{*}$post error not_configured \
			"No OpenAI API key — add one in Preferences ▸ Agent (a local OpenAI-compatible server may need none: set its URL and any placeholder key)"
		return
	}
	set auth [list Authorization "Bearer $key"]
	# The core owns the system prompt (D34); merge it into a LOCAL config copy so the
	# persistent config dict stays clean. infer skips an empty `system`.
	set conf $config
	dict set conf system $system
	rio::openai::infer $conf $conversation $tools $auth $transport $post
}

# Whether a key is stored (the GUI offers Set / Clear accordingly).
proc rio::openai::api::configured {} {
	variable config
	return [rio::secret::has [dict get $config secret_name]]
}

# Store / replace the API key (a 0600 secret, apart from settings; D21).
proc rio::openai::api::set_key {key} {
	variable config
	rio::secret::save [dict get $config secret_name] [dict create api_key $key]
}

proc rio::openai::api::clear_key {} {
	variable config
	rio::secret::forget [dict get $config secret_name]
}

# The stored API key, or "" if none is set.
proc rio::openai::api::_api_key {} {
	variable config
	set s [rio::secret::get [dict get $config secret_name]]
	return [expr {[dict exists $s api_key] ? [dict get $s api_key] : ""}]
}

# Register with the agent's named-provider registry (D26/D30) so a frontend can
# select this face by name over the channel (agent.provider.set openai) and render
# its picker/key dialog from the declared label + signup. The key capability routes
# agent.key.* to this face's own 0600 store — its key coexists with Claude's.
rio::agent::register_provider openai rio::openai::api::provider \
	-label  ChatGPT \
	-signup platform.openai.com/api-keys \
	-key [dict create \
		set    rio::openai::api::set_key \
		clear  rio::openai::api::clear_key \
		status rio::openai::api::configured]
