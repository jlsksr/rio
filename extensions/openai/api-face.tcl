# extensions/openai — the OpenAI-compatible API face (AGENTS.md D8, D26).
#
# MIT-licensed, like rio itself (D121). The notice is IN this file because an installed
# extension travels alone: rio writes the payload into your extension directory, and there
# is no LICENSE beside it there (D122).
#
# Copyright (c) 2026 Julius Kaiser <jkdata@mailbox.org>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to the following
# conditions:
#
# The above copyright notice and this permission notice shall be included in all copies
# or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
# CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
# OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
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
	# The hosted endpoint, as a named constant: `base_url` still standing at this value
	# is what "the user has not pointed rio anywhere else" means, and that is the one
	# case where a missing key is worth saying something about rather than letting the
	# server answer. A named constant, not a hostname test — this face has no opinion
	# about which hosts are OpenAI's.
	variable default_base_url https://api.openai.com/v1

	# Config-as-data. `base_url` is the single source for both endpoints — this face
	# speaks to anything that answers the OpenAI protocol, and for a self-hosted server
	# (Ollama, llama-server, llama-swap, vLLM, LM Studio) the URL is the first thing a
	# user has to set, so it is a declared option rather than a line in this file.
	# `messages_url` / `models_url` stay as overrides for a server whose paths sit
	# somewhere else; blank means "derive from base_url".
	#
	# `token_param` is the request key for the output cap: hosted newer OpenAI models
	# require `max_completion_tokens`, while older models and most local servers take
	# `max_tokens` — and a server that refuses one names the other in its 400, which is
	# how `token_models` gets filled (D106c). The `system` prompt is not static config:
	# the core composes it per turn and the provider merges it in (D34).
	variable config [dict create \
		base_url        https://api.openai.com/v1 \
		messages_url    "" \
		models_url      "" \
		model           gpt-4o \
		effort          default \
		reasoning       show \
		extra_json      "" \
		token_param     max_tokens \
		token_models    "" \
		effort_models   "" \
		max_tokens      4096 \
		request_timeout 600000 \
		secret_name     openai-api]

	# How an effort choice is spelled on the wire, %v standing for the value (D106).
	# Config-as-data like the rest: a server that wants a different key is one line.
	variable effort_json {"reasoning_effort":"%v"}

	# The models offered in the picker. Short and shipped: the option is `free` (type
	# any id) and `refresh` re-lists from the server itself — which is the only
	# sensible answer for a local Ollama / llama-server / LM Studio, whose models are
	# whatever that machine happens to have pulled.
	variable models {
		{value gpt-4o      label "GPT-4o"}
		{value gpt-4o-mini label "GPT-4o mini"}
	}
	variable efforts {
		{value default label "Provider default"}
		{value low     label "Low"}
		{value medium  label "Medium"}
		{value high    label "High"}
	}

	# Network seams: the shared tcltls streaming transport for a turn and the plain
	# GET for a models listing (plugins/lib/transport.tcl); tests inject fakes.
	variable transport rio::llm::http::stream
	variable fetcher   rio::llm::http::get
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
	variable default_base_url
	set key [_api_key]
	set url [_messages_url]
	# A key is OPTIONAL: most self-hosted servers want none, and inventing a placeholder
	# to get past a check was the old advice. So the request simply goes out without an
	# Authorization header and the server decides. The one case still worth naming is a
	# user who has not pointed rio anywhere — then this really is hosted OpenAI, which
	# really does need a key, and a 401 would be a worse way to learn it.
	if {$key eq "" && $url eq "$default_base_url/chat/completions"} {
		{*}$post error not_configured \
			"No OpenAI API key — add one in Preferences ▸ Agent, or set a server URL there if you are running your own (most need no key)"
		return
	}
	set auth {}
	if {$key ne ""} { set auth [list Authorization "Bearer $key"] }
	# The core owns the system prompt (D34); merge it into a LOCAL config copy so the
	# persistent config dict stays clean. infer skips an empty `system`.
	set conf $config
	dict set conf messages_url $url
	dict set conf system $system
	dict set conf effort_json [_effort_json]
	# Which token-cap parameter this model wants, and where to record the answer if
	# the server corrects us (D106c).
	dict set conf token_param [_token_param]
	dict set conf token_learn rio::openai::api::_token_learned
	dict set conf effort_learn rio::openai::api::_effort_learned
	rio::openai::infer $conf $conversation $tools $auth $transport $post
}

# --- the token cap's parameter name, learned per model (D106c) ----------------

# `token_models` is the list of model ids this provider has been TOLD want
# `max_completion_tokens` — by the server, in a 400. Everything else gets the
# configured default (`max_tokens`, which is what local OpenAI-compatible servers
# and the older hosted models take). Config-as-data still: the list is an ordinary
# settings key a user can read, edit or empty by hand.
proc rio::openai::api::_token_param {} {
	variable config
	if {[lsearch -exact [dict get $config token_models] [dict get $config model]] >= 0} {
		return max_completion_tokens
	}
	return [dict get $config token_param]
}

# Remember what the refusal taught us, so the retry happens once per model ever and
# not once per turn. Persisted beside the model and effort choices (D106).
proc rio::openai::api::_token_learned {model param} {
	variable config
	if {$param ne "max_completion_tokens" || $model eq ""} return
	set l [dict get $config token_models]
	if {[lsearch -exact $l $model] >= 0} return
	lappend l $model
	dict set config token_models $l
	catch {rio::agent::settings::store openai token_models $l}
}

# --- the options a frontend may offer (D106) ---------------------------------

# The effort fragment for the live choice, or "" for `default`. Default matters more
# here than anywhere: `reasoning_effort` is REJECTED by a non-reasoning model (gpt-4o)
# and by most local servers, so rio keeps sending exactly what it always sent until
# the user picks otherwise.
proc rio::openai::api::_effort_json {} {
	variable config
	variable effort_json
	set e [dict get $config effort]
	if {$e eq "" || $e eq "default"} { return "" }
	# A model the server has already refused the field for (D106d) sends nothing. The
	# stored choice is deliberately NOT rewritten: support is per model while the
	# choice is per provider, so switching back to a reasoning model restores it —
	# the rule D106a settled for Claude, reached here by being told instead of asking.
	if {[_effort_refused [dict get $config model]]} { return "" }
	return [string map [list %v $e] $effort_json]
}

# The models this provider has been TOLD refuse `reasoning_effort` — gpt-4o and most
# local servers. Learned from the 400, never guessed from the model's name.
proc rio::openai::api::_effort_refused {model} {
	variable config
	return [expr {[lsearch -exact [dict get $config effort_models] $model] >= 0}]
}

proc rio::openai::api::_effort_learned {model _value} {
	variable config
	if {$model eq ""} return
	set l [dict get $config effort_models]
	if {[lsearch -exact $l $model] >= 0} return
	lappend l $model
	dict set config effort_models $l
	catch {rio::agent::settings::store openai effort_models $l}
}

proc rio::openai::api::options {} {
	variable config
	variable models
	variable efforts
	set m [dict get $config model]
	# Once the server has refused the field for this model, say so with the model's
	# own name and offer only the default — the same honesty D106a gives Claude, but
	# learned from a refusal rather than read from a capabilities listing, because
	# OpenAI's /v1/models carries none. The stored choice still shows, and comes back
	# when a model that takes an effort is chosen again.
	if {[_effort_refused $m]} {
		set ehint "Reasoning effort. $m does not accept one — the server said so — and rio sends none. Choose a reasoning model (o3, o4-mini, gpt-5…) to use this."
		set echoices [list [lindex $efforts 0]]
	} else {
		set ehint "Reasoning effort. Provider default sends nothing — gpt-4o and most local servers refuse the field."
		set echoices $efforts
	}
	# `quick` says which of these belong in the chat strip's menu as well as the
	# settings window: the two you change between turns, and not the six you set once
	# when you point rio at a server.
	set tokhint "Which request field carries the output cap. Most servers want max_tokens; newer hosted OpenAI models want max_completion_tokens and say so in a 400, which rio then remembers per model — a model in that list keeps its learned answer whatever is chosen here."
	return [list \
		[dict create name model label Model group Model \
			hint "Which model answers. Refresh to list what this server offers — after changing the base URL, refresh first." \
			value $m free 1 refresh 1 choices $models] \
		[dict create name effort label Effort group Model \
			hint $ehint \
			value [dict get $config effort] free 0 refresh 0 choices $echoices] \
		[dict create name reasoning label Reasoning group Model quick 0 \
			hint "Whether a thinking model's reasoning is shown in the chat. It is never part of the answer and is never sent back to the model." \
			value [dict get $config reasoning] \
			choices {{value show label "Show it"} {value hide label "Hide it"}}] \
		[dict create name base_url label "Server URL" group Server kind text quick 0 \
			hint "The API base, without a trailing path: https://api.openai.com/v1, or your own server (Ollama, llama-server, vLLM, LM Studio). rio adds /chat/completions and /models itself. A self-hosted server usually needs no API key." \
			value [dict get $config base_url]] \
		[dict create name max_tokens label "Max tokens" group Server kind number quick 0 \
			hint "The cap on one reply's length." \
			value [dict get $config max_tokens]] \
		[dict create name request_timeout label "Request timeout (ms)" group Server \
			kind number quick 0 \
			hint "How long one whole turn may take, including the model's thinking and the wait for a server that loads a model on demand. It bounds the WHOLE exchange, not the idle time, so a long generation needs a generous value." \
			value [dict get $config request_timeout]] \
		[dict create name token_param label "Token cap field" group Server quick 0 \
			hint $tokhint \
			value [dict get $config token_param] \
			choices {{value max_tokens label max_tokens} \
			         {value max_completion_tokens label max_completion_tokens}}] \
		[dict create name messages_url label "Completions URL" group Advanced kind text quick 0 \
			hint "Blank: derived from the server URL. Set it only for a server whose completions path is somewhere else." \
			value [dict get $config messages_url]] \
		[dict create name models_url label "Models URL" group Advanced kind text quick 0 \
			hint "Blank: derived from the server URL. Set it only for a server whose model list is somewhere else." \
			value [dict get $config models_url]] \
		[dict create name extra_json label "Extra request JSON" group Advanced kind text quick 0 \
			hint "A JSON object merged into every request — temperature, top_p, or whatever this server understands (llama.cpp and vLLM take chat_template_kwargs). Fields rio sends itself are refused here; set those above." \
			value [dict get $config extra_json]]]
}

proc rio::openai::api::option_set {name value} {
	variable config
	variable efforts
	switch -- $name {
		model {
			if {[string trim $value] eq ""} {
				rio::error::raise bad_request "model must not be empty"
			}
			dict set config model [string trim $value]
		}
		effort {
			set ok {}
			foreach c $efforts { lappend ok [dict get $c value] }
			if {$value ni $ok} {
				rio::error::raise bad_request "effort must be one of: [join $ok {, }]"
			}
			dict set config effort $value
		}
		reasoning {
			if {$value ni {show hide}} {
				rio::error::raise bad_request "reasoning must be show or hide"
			}
			dict set config reasoning $value
		}
		base_url {
			# Canonicalized so the window shows what will actually be used: a trailing
			# slash, and the completions path a user pastes straight out of the server's
			# own documentation, both come off.
			set v [string trim $value]
			if {$v eq ""} { rio::error::raise bad_request "the server URL must not be empty" }
			if {![regexp -nocase {^https?://} $v]} {
				rio::error::raise bad_request "the server URL must start with http:// or https://"
			}
			if {[string match */chat/completions $v]} { set v [string range $v 0 end-17] }
			dict set config base_url [string trimright $v /]
		}
		messages_url - models_url {
			set v [string trim $value]
			if {$v ne "" && ![regexp -nocase {^https?://} $v]} {
				rio::error::raise bad_request "$name must start with http:// or https://, or be empty to derive it"
			}
			dict set config $name $v
		}
		max_tokens - request_timeout {
			if {![string is integer -strict $value] || $value <= 0} {
				rio::error::raise bad_request "$name must be a positive whole number"
			}
			dict set config $name $value
		}
		token_param {
			if {$value ni {max_tokens max_completion_tokens}} {
				rio::error::raise bad_request \
					"the token cap field must be max_tokens or max_completion_tokens"
			}
			dict set config token_param $value
		}
		extra_json { dict set config extra_json [_check_extra [string trim $value]] }
		default { rio::error::raise bad_request "unknown option: $name" }
	}
	rio::agent::settings::store openai $name [dict get $config $name]
	return
}

# Validate the user's own request fields, and return what to store.
#
# It is checked but never rebuilt. tcllib flattens every JSON leaf to a string, so
# re-serialising would send "true" where the user wrote true — a type change nobody
# asked for. The body therefore splices this text RAW, and the way to be sure that
# cannot produce a duplicate key (which every server resolves differently, none of them
# documented) is to refuse the keys rio emits itself. The forbidden set is COMPUTED, not
# written out: the token-cap field is a live setting and the effort field is spelled in
# one config-as-data fragment, so an upstream rename stays the one-line edit D106 made it.
proc rio::openai::api::_check_extra {v} {
	variable config
	variable effort_json
	if {$v eq ""} { return "" }
	if {[catch {json::json2dict $v} d] || ![string match "\{*" $v]} {
		rio::error::raise bad_request "extra request JSON must be a JSON object, e.g. {\"temperature\":0.2}"
	}
	set mine [list model messages stream tools [dict get $config token_param]]
	if {[regexp {"([^"]+)"} $effort_json -> ekey]} { lappend mine $ekey }
	foreach k [dict keys $d] {
		if {$k in $mine} {
			rio::error::raise bad_request \
				"rio sends \"$k\" itself — set it with the option above rather than here"
		}
	}
	# One line, because a settings value is one line (rio::agent::settings). Safe rather
	# than lossy: RFC 8259 forbids a raw control character inside a JSON string, so in a
	# document that has already parsed, every raw newline is whitespace between tokens.
	# Normalising beats refusing a pretty-printed paste.
	return [string map [list \n " " \r " " \t " "] $v]
}

# The two endpoints, both derived from `base_url` unless explicitly overridden. Every
# server this face targets — hosted OpenAI, Ollama, llama-server, llama-swap, LM Studio,
# vLLM — publishes the same two paths under one base, so a user sets one URL and both
# follow. The override exists for the server that does not.
proc rio::openai::api::_messages_url {} {
	variable config
	set u [dict get $config messages_url]
	if {$u ne ""} { return $u }
	return "[dict get $config base_url]/chat/completions"
}
proc rio::openai::api::_models_url {} {
	variable config
	set u [dict get $config models_url]
	if {$u ne ""} { return $u }
	return "[dict get $config base_url]/models"
}

# Re-list what this server offers. Asynchronous (D10); a failure leaves the choices
# alone and says why.
proc rio::openai::api::option_refresh {name announce} {
	variable fetcher
	if {$name ne "model"} { rio::error::raise bad_request "cannot refresh: $name" }
	set key [_api_key]
	set headers {}
	# A local server usually needs no key; the hosted API always does. Send one when
	# we have one, and let the server say no when we don't.
	if {$key ne ""} { set headers [list Authorization "Bearer $key"] }
	{*}$fetcher [dict create url [_models_url] headers $headers] \
		[list rio::openai::api::_models_done $announce]
	return
}

# The listing -> the picker's choices. The OpenAI shape is {"data":[{"id":…}, …]},
# which every compatible server copies; the id is both value and label (these servers
# publish no display name).
proc rio::openai::api::_models_done {announce status err body} {
	variable models
	if {$status == 0} {
		{*}$announce "Couldn't reach the model list ($err)"
		return
	}
	if {$status != 200} {
		{*}$announce "The server refused the model list (HTTP $status)"
		return
	}
	if {[catch {json::json2dict $body} d] || ![dict exists $d data]} {
		{*}$announce "Couldn't read the model list from the server"
		return
	}
	set out {}
	foreach m [dict get $d data] {
		if {![dict exists $m id]} continue
		lappend out [dict create value [dict get $m id] label [dict get $m id]]
	}
	if {[llength $out]} { set models [lsort -index 1 $out] }
	{*}$announce
	return
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
	-label  "OpenAI-compatible" \
	-signup "platform.openai.com/api-keys (hosted OpenAI; a server of your own usually needs no key)" \
	-key [dict create \
		set    rio::openai::api::set_key \
		clear  rio::openai::api::clear_key \
		status rio::openai::api::configured] \
	-options [dict create \
		list    rio::openai::api::options \
		set     rio::openai::api::option_set \
		refresh rio::openai::api::option_refresh]

# Adopt the choices the user made last time (D106), from the flat, hand-editable
# $XDG_CONFIG_HOME/rio/agent/providers/openai.conf — beside this provider's prompt
# layer and allow-list. Absent file, shipped defaults.
proc rio::openai::api::_adopt_settings {} {
	variable config
	# token_models is not a user CHOICE but something the server taught this provider
	# (D106c) — it persists the same way, so a restart doesn't re-learn it.
	foreach k {model effort reasoning base_url messages_url models_url \
			max_tokens request_timeout token_param extra_json \
			token_models effort_models} {
		set v [rio::agent::settings::get openai $k]
		if {$v ne ""} { dict set config $k $v }
	}
}
rio::openai::api::_adopt_settings
