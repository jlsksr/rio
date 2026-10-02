# extensions/openai — the OpenAI-compatible API face (D8, D26).
#
# MIT, like rio (D121). The notice is in this file because an installed
# extension has no LICENSE beside it (D122).
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
# An OpenAI-compatible provider. It authenticates with a Bearer key and
# drives rio::openai::infer. The default endpoint is hosted ChatGPT; the
# endpoint is data, so the same face drives Ollama, llama-server, LM Studio
# and vLLM (D8). This face owns the auth header, the config and the key's
# storage, nothing else.
#
# Whatever may change (endpoint, model, token-cap field, timeout) is data in
# `config`, settable at runtime (D26). The network is a seam, so the tests
# run offline.

package require json

namespace eval rio::openai::api {
	# The hosted endpoint. `base_url` still at this value means the user has
	# pointed rio nowhere else: the one case where a missing key is reported
	# here, before the server is asked. A constant, not a hostname test.
	variable default_base_url https://api.openai.com/v1

	#   base_url         both endpoints derive from it; the first thing to
	#                    set for a server of your own
	#   messages_url,    overrides, for a server whose paths differ;
	#   models_url       blank = derive from base_url
	#   token_param      the field that carries the output cap. Newer hosted
	#                    models want max_completion_tokens; older ones and
	#                    most local servers max_tokens. A server names the
	#                    other in its 400, which fills token_models (D106c)
	#   secret_name      per profile (D131), so a switch to a local server
	#                    does not send a hosted vendor's key to localhost
	#   extra_json_file  a file, not the JSON: a settings value is one line,
	#                    and chat_template_kwargs is a nested object
	#
	# The system prompt is not here: the core composes it per turn (D34).
	variable config [dict create \
		base_url        https://api.openai.com/v1 \
		messages_url    "" \
		models_url      "" \
		model           gpt-4o \
		effort          default \
		reasoning       show \
		extra_json_file "" \
		token_param     max_tokens \
		token_models    "" \
		effort_models   "" \
		models_cached   "" \
		max_tokens      4096 \
		request_timeout 600000 \
		secret_name     openai-api]

	# The shipped values. A profile switch resets to them first, or a key
	# the new profile omits would keep the old profile's value.
	variable defaults $config

	# The active profile. "" before the first adopt, and on a host with
	# nowhere to save.
	variable profile ""

	# How an effort is spelled in the request; %v is the value (D106). Data:
	# a server that wants another key is a one-line change.
	variable effort_json {"reasoning_effort":"%v"}

	# The models in the picker. Short: any id can be typed, and refresh asks
	# the server, the only answer that fits a local one.
	variable models_default {
		{value gpt-4o      label "GPT-4o"}
		{value gpt-4o-mini label "GPT-4o mini"}
	}
	variable models $models_default
	variable efforts {
		{value default label "Provider default"}
		{value low     label "Low"}
		{value medium  label "Medium"}
		{value high    label "High"}
	}

	# Network seams: the streaming transport for a turn, a plain GET for the
	# model list (plugins/lib/transport.tcl). Tests put fakes here.
	variable transport rio::llm::http::stream
	variable fetcher   rio::llm::http::get

	# The profiles a first run starts with, one per kind of server. Written
	# once (the D39 seed rule): a deleted one stays deleted, an edited one
	# survives an upgrade.
	#
	# The two local ones are examples, on llama-swap's usual port. They show
	# the shape: no key, a bigger token cap, and thinking set in the
	# extra-JSON file, since most compatible servers refuse `effort`.
	variable seeds {
		{ChatGPT {
			base_url    https://api.openai.com/v1
			model       gpt-4o
			max_tokens  4096
			token_param max_tokens
			secret_name openai-api
		}}
		{"Qwen3.8 27B (local)" {
			base_url    http://127.0.0.1:1080/v1
			model       coder-large
			max_tokens  32768
			token_param max_tokens
			secret_name openai-local
		}}
		{"Qwen3.8 Flash Next (local)" {
			base_url    http://127.0.0.1:1080/v1
			model       flash-next
			max_tokens  32768
			token_param max_tokens
			secret_name openai-local
		}}
	}

	# The extra-request JSON of each seeded profile, by name. None for
	# ChatGPT: it wants none.
	variable seed_extra {
		{"Qwen3.8 27B (local)" {{
  "chat_template_kwargs": {
    "enable_thinking": true,
    "reasoning_effort": "medium"
  }
}}}
		{"Qwen3.8 Flash Next (local)" {{
  "chat_template_kwargs": {
    "enable_thinking": true,
    "reasoning_effort": "xhigh"
  }
}}}
	}
}

# Set one config key: a user setting, a test, a model or endpoint choice.
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
	# A key is optional: most self-hosted servers want none, so the request
	# goes without an Authorization header and the server decides. Only
	# hosted OpenAI, the untouched default, is refused here: it does need a
	# key, and a 401 says so worse.
	if {$key eq "" && $url eq "$default_base_url/chat/completions"} {
		{*}$post error not_configured \
			"No OpenAI API key — add one in Extensions ▸ OpenAI-compatible…, or set a server URL there if you are running your own (most need no key)"
		return
	}
	set auth {}
	if {$key ne ""} { set auth [list Authorization "Bearer $key"] }
	# The user's own request fields, read and checked each turn: the file
	# may change at any time. A file that does not parse, or sets a field
	# rio sends, stops the turn and says which. Dropping fields someone
	# wrote would be worse (D26).
	if {[catch {_extra_text} extra]} {
		{*}$post error bad_request "Your extra request JSON couldn't be used: $extra"
		return
	}
	# The core owns the system prompt (D34). It goes into a copy, so
	# `config` stays clean; infer skips an empty one.
	set conf $config
	dict set conf messages_url $url
	dict set conf extra_json $extra
	dict set conf system $system
	dict set conf effort_json [_effort_json]
	# The token-cap field this model wants, and the procs that record a
	# server's correction (D106c, D106d).
	dict set conf token_param [_token_param]
	dict set conf token_learn rio::openai::api::_token_learned
	dict set conf effort_learn rio::openai::api::_effort_learned
	rio::openai::infer $conf $conversation $tools $auth $transport $post
}

# --- the extra-request-JSON file (D131) --------------------------------------
#
# The value is a bare file name, in this provider's directory beside the
# profiles. Not a path: a name without separators cannot point outside (as
# D39 treats a remote name), and "relative to what?" has no good answer
# over a remote core (D30). For a file elsewhere, symlink.
proc rio::openai::api::_extra_name_ok {n} {
	if {$n in {"" . ..}} { return 0 }
	if {[string index $n 0] eq "."} { return 0 }
	if {[string trim $n] ne $n} { return 0 }
	return [regexp {^[A-Za-z0-9._ ()-]+$} $n]
}

proc rio::openai::api::_extra_path {n} {
	if {![_extra_name_ok $n]} {
		rio::error::raise bad_request \
			"an extra-JSON file name may use letters, digits, spaces and . _ - ( ) — not '$n'"
	}
	set d [rio::agent::settings::profile_dir openai]
	if {$d eq ""} { rio::error::raise io_error "nowhere to keep an extra-JSON file" }
	return [file join $d $n]
}

# The file name a profile gets when it names none. Per profile, so a
# Duplicate does not share one file.
proc rio::openai::api::_extra_default_name {} {
	variable profile
	return [expr {$profile eq "" ? "openai.extra.json" : "$profile.extra.json"}]
}

# The text to splice into a request: the file's contents, checked. A
# missing file is the same as naming none.
proc rio::openai::api::_extra_text {} {
	variable config
	set n [dict get $config extra_json_file]
	if {$n eq ""} { return "" }
	set p [_extra_path $n]
	if {![file isfile $p]} { return "" }
	set fh [open $p r]
	fconfigure $fh -encoding utf-8
	set t [::read $fh]
	close $fh
	return [_check_extra $t]
}

# --- the token cap's parameter name, learned per model (D106c) ----------------

# `token_models` lists the models a server's 400 said want
# max_completion_tokens. Every other model gets `token_param`. An ordinary
# setting: read it, edit it or empty it by hand.
proc rio::openai::api::_token_param {} {
	variable config
	if {[lsearch -exact [dict get $config token_models] [dict get $config model]] >= 0} {
		return max_completion_tokens
	}
	return [dict get $config token_param]
}

# Remember what the 400 taught, so the retry happens once per model, not
# once per turn. Saved beside the model and effort (D106).
proc rio::openai::api::_token_learned {model param} {
	variable config
	if {$param ne "max_completion_tokens" || $model eq ""} return
	set l [dict get $config token_models]
	if {[lsearch -exact $l $model] >= 0} return
	lappend l $model
	dict set config token_models $l
	catch {_store token_models $l}
}

# Save one key into the active profile (D131). With none, into the flat
# file, where a pre-profiles install keeps its settings until the first
# adopt.
proc rio::openai::api::_store {key value} {
	variable profile
	return [rio::agent::settings::store openai $key $value $profile]
}

# --- the options a frontend may offer (D106) ---------------------------------

# The effort fragment for the request, or "" for `default`. gpt-4o and most
# local servers reject `reasoning_effort`, so nothing is sent until the user
# chooses.
proc rio::openai::api::_effort_json {} {
	variable config
	variable effort_json
	set e [dict get $config effort]
	if {$e eq "" || $e eq "default"} { return "" }
	# Nothing for a model the server refused it for (D106d). The stored
	# choice stays: support is per model, the choice per provider, so a
	# reasoning model gets it back (D106a).
	if {[_effort_refused [dict get $config model]]} { return "" }
	return [string map [list %v $e] $effort_json]
}

# Whether a 400 said this model refuses `reasoning_effort`. Learned, never
# guessed from a name.
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
	catch {_store effort_models $l}
}

proc rio::openai::api::options {} {
	variable config
	variable models
	variable efforts
	set m [dict get $config model]
	# After a refusal, say so by the model's name and offer only the
	# default. Learned from the 400: /v1/models lists no capabilities. The
	# stored choice still shows, and applies again with a model that takes
	# one.
	if {[_effort_refused $m]} {
		set ehint "Reasoning effort. $m does not accept one — the server said so — and rio sends none. Choose a reasoning model (o3, o4-mini, gpt-5…) to use this."
		set echoices [list [lindex $efforts 0]]
	} else {
		set ehint "Reasoning effort. Provider default sends nothing — gpt-4o and most local servers refuse the field."
		set echoices $efforts
	}
	# `quick 0` keeps an option out of the chat strip's menu. The strip
	# gets the two you change between turns: model and effort.
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
		[dict create name extra_json_file label "Extra request JSON" group Advanced \
			kind text file 1 quick 0 \
			hint "A file holding a JSON object merged into every request — temperature, top_p, or whatever this server understands (llama.cpp and vLLM take chat_template_kwargs). Edit… opens it in the editor. It is read fresh every turn, so a change takes effect on the next one. Fields rio sends itself are refused; set those above. Blank sends nothing extra." \
			value [dict get $config extra_json_file]]]
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
			# Canonical, so the window shows what is used: a trailing slash
			# and a pasted /chat/completions both come off.
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
		extra_json_file {
			# Only the name is checked here. The contents are checked each
			# turn: the file stays editable.
			set v [string trim $value]
			if {$v ne ""} { _extra_path $v }
			dict set config extra_json_file $v
		}
		default { rio::error::raise bad_request "unknown option: $name" }
	}
	_store $name [dict get $config $name]
	return
}

# Resolve and create the file an option names (the `file` capability,
# D131). With none named, the usual case, pick this profile's default name
# and record it.
proc rio::openai::api::option_file {name} {
	variable config
	if {$name ne "extra_json_file"} {
		rio::error::raise bad_request "option '$name' names no file"
	}
	set n [dict get $config extra_json_file]
	if {$n eq ""} {
		set n [_extra_default_name]
		option_set extra_json_file $n
	}
	set p [_extra_path $n]
	set created 0
	if {![file isfile $p]} {
		file mkdir [file dirname $p]
		set fh [open $p w 0600]
		fconfigure $fh -encoding utf-8
		# An empty object, not an empty file: valid, sends nothing, shows
		# the shape.
		puts $fh "{}"
		close $fh
		set created 1
	}
	return [dict create path $p created $created]
}

# Check the user's own request fields; return the text to splice.
#
# Checked, never rebuilt: tcllib turns every JSON leaf into a string, so a
# rebuilt `true` would go out as "true". The text is spliced raw, so the
# keys rio sends itself are refused: a duplicate key means something
# different on every server. That set is computed from the live settings,
# not listed, so an upstream rename stays a one-line edit (D106).
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
	# Onto one line. Lossless: a JSON string holds no raw control
	# character (RFC 8259), so in a document that parsed, every newline
	# is whitespace between tokens.
	return [string map [list \n " " \r " " \t " "] $v]
}

# The two endpoints, derived from `base_url` unless overridden. Every
# server this face targets serves both paths under one base.
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

# List what this server offers. Asynchronous (D10). A failure keeps the
# choices and says why.
proc rio::openai::api::option_refresh {name announce} {
	variable fetcher
	if {$name ne "model"} { rio::error::raise bad_request "cannot refresh: $name" }
	set key [_api_key]
	set headers {}
	# Send a key if there is one; a local server usually needs none.
	if {$key ne ""} { set headers [list Authorization "Bearer $key"] }
	{*}$fetcher [dict create url [_models_url] headers $headers] \
		[list rio::openai::api::_models_done $announce]
	return
}

# The listing -> the picker's choices:
#
#   {"data":[{"id":...}, ...]}
#
# The id is value and label: these servers publish no display name.
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
	# Saved per profile (D131): the list belongs to its server. A switch
	# must not show another server's models; a switch back needs no
	# refresh.
	if {[llength $out]} {
		set models [lsort -index 1 $out]
		catch {_store models_cached $models}
	}
	{*}$announce
	return
}

# Whether a key is stored: the GUI offers Set or Clear.
proc rio::openai::api::configured {} {
	variable config
	return [rio::secret::has [dict get $config secret_name]]
}

# Store the API key: a 0600 secret, apart from settings (D21).
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

# Register by name (D26, D30), so a frontend can select this face over the
# channel (agent.provider.set openai) and build its picker and key dialog
# from the label and signup. agent.key.* reaches this face's own 0600
# store.
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
		refresh rio::openai::api::option_refresh \
		file    rio::openai::api::option_file] \
	-profiles [dict create \
		list   rio::openai::api::profiles_list \
		switch rio::openai::api::profile_switch \
		add    rio::openai::api::profile_add \
		remove rio::openai::api::profile_remove \
		rename rio::openai::api::profile_rename]

# --- profiles (D131) ---------------------------------------------------------
#
# A profile is a named configuration. The core stores it
# (rio::agent::settings); this face gives it meaning: which keys it holds,
# that a switch adopts them, that the extra-JSON file goes with its profile.

proc rio::openai::api::profiles_list {} {
	variable profile
	return [dict create \
		profiles [rio::agent::settings::profiles openai] \
		active   $profile]
}

# Switch. The pointer to the active profile is a key in the flat file, the
# one thing not per profile.
proc rio::openai::api::profile_switch {name} {
	variable profile
	if {![rio::agent::settings::profile_exists openai $name]} {
		rio::error::raise bad_request "no such profile: $name"
	}
	set profile $name
	catch {rio::agent::settings::store openai profile $name}
	_adopt
	return $name
}

# Create. A Duplicate copies the source's extra-JSON file under the new
# name, or editing the copy would change the original.
proc rio::openai::api::profile_add {name {from ""}} {
	rio::agent::settings::profile_add openai $name $from
	if {$from ne ""} { _copy_extra $from $name }
	return $name
}

# Remove, but never the last one: settings live in a profile, and the rest
# assumes one is always active.
proc rio::openai::api::profile_remove {name} {
	variable profile
	if {[llength [rio::agent::settings::profiles openai]] <= 1} {
		rio::error::raise bad_request \
			"'$name' is the only profile — rename or edit it, or add another first"
	}
	set own [_owned_extra $name]
	rio::agent::settings::profile_remove openai $name
	# Its extra-JSON file goes too, but only the one named after it: any
	# other may serve another profile.
	if {$own ne ""} { catch {file delete -- $own} }
	if {$name eq $profile} {
		profile_switch [lindex [rio::agent::settings::profiles openai] 0]
	}
	return $name
}

proc rio::openai::api::profile_rename {name to} {
	variable profile
	variable config
	set own [_owned_extra $name]
	rio::agent::settings::profile_rename openai $name $to
	# The extra file named after the profile follows it.
	if {$own ne ""} {
		set dst [file join [file dirname $own] "$to.extra.json"]
		if {![file exists $dst]} {
			catch {file rename -- $own $dst}
			catch {rio::agent::settings::store openai extra_json_file "$to.extra.json" $to}
		}
	}
	if {$name eq $profile} {
		set profile $to
		catch {rio::agent::settings::store openai profile $to}
		if {$own ne ""} { dict set config extra_json_file "$to.extra.json" }
	}
	return $to
}

# The extra-JSON file a profile owns, the one named after it. "" if it
# names another, names none, or the file is gone.
proc rio::openai::api::_owned_extra {name} {
	set n [rio::agent::settings::get openai extra_json_file "" $name]
	if {$n ne "$name.extra.json"} { return "" }
	if {[catch {_extra_path $n} p] || ![file isfile $p]} { return "" }
	return $p
}

proc rio::openai::api::_copy_extra {from to} {
	set src [_owned_extra $from]
	if {$src eq ""} { return }
	set dst [file join [file dirname $src] "$to.extra.json"]
	if {[file exists $dst]} { return }
	catch {file copy -- $src $dst}
	catch {rio::agent::settings::store openai extra_json_file "$to.extra.json" $to}
}

# --- adopting what the user chose last time (D106, D131) ---------------------

# Every key this face saves. `token_models` and `effort_models` are not
# choices but what a server taught (D106c, D106d); they are per profile
# too, being facts about that server.
namespace eval rio::openai::api {
	variable persisted {
		model effort reasoning base_url messages_url models_url
		max_tokens request_timeout token_param extra_json_file
		token_models effort_models models_cached secret_name
	}
}

# Reset to the shipped values, then read the active profile over them.
# Without the reset, a switch would keep the keys the new profile omits.
proc rio::openai::api::_adopt {} {
	variable config ; variable defaults ; variable persisted ; variable profile
	variable models ; variable models_default
	set config $defaults
	set models $models_default
	foreach k $persisted {
		set v [rio::agent::settings::get openai $k "" $profile]
		if {$v ne ""} { dict set config $k $v }
	}
	set cached [dict get $config models_cached]
	if {[llength $cached]} { set models $cached }
}

# First run: seed the shipped profiles, carry a pre-profiles configuration
# forward, pick the active one. Runs once, while the profile directory does
# not exist (the D39 rule).
proc rio::openai::api::_seed {} {
	variable seeds ; variable seed_extra ; variable persisted
	set dir [rio::agent::settings::profile_dir openai]
	if {$dir eq "" || [file isdirectory $dir]} { return }

	# What a pre-D131 install left in the flat file is a configuration in
	# use. It becomes a profile, and the active one.
	set old [rio::agent::settings::load openai]
	dict unset old profile

	foreach pair $seeds {
		lassign $pair name vals
		if {[catch {rio::agent::settings::profile_add openai $name}]} continue
		dict for {k v} $vals { catch {rio::agent::settings::store openai $k $v $name} }
	}
	foreach pair $seed_extra {
		lassign $pair name text
		set fn "$name.extra.json"
		catch {
			set fh [open [file join $dir $fn] w 0600]
			fconfigure $fh -encoding utf-8
			puts -nonewline $fh $text
			close $fh
			rio::agent::settings::store openai extra_json_file $fn $name
		}
	}

	set active [lindex [lindex [lindex $seeds 0] 0] 0]
	if {[llength [dict keys $old]]} { set active [_migrate $old] }
	catch {rio::agent::settings::store openai profile $active}
}

# Carry a pre-profiles configuration into a profile of its own; return its
# name. Its one-line `extra_json` becomes a file.
proc rio::openai::api::_migrate {old} {
	variable persisted
	set name "Current settings"
	set n 2
	while {[rio::agent::settings::profile_exists openai $name]} {
		set name "Current settings ($n)" ; incr n
	}
	rio::agent::settings::profile_add openai $name
	foreach k $persisted {
		if {[dict exists $old $k]} {
			catch {rio::agent::settings::store openai $k [dict get $old $k] $name}
		}
	}
	if {[dict exists $old extra_json] && [string trim [dict get $old extra_json]] ne ""} {
		set fn "$name.extra.json"
		catch {
			set fh [open [file join [rio::agent::settings::profile_dir openai] $fn] w 0600]
			fconfigure $fh -encoding utf-8
			puts $fh [string trim [dict get $old extra_json]]
			close $fh
			rio::agent::settings::store openai extra_json_file $fn $name
		}
	}
	return $name
}

# Seed on a first run, then adopt the profile the pointer names. A pointer
# to a deleted profile falls back to the first that exists.
proc rio::openai::api::_adopt_settings {} {
	variable profile
	catch {_seed}
	set all [rio::agent::settings::profiles openai]
	set want [rio::agent::settings::get openai profile]
	if {$want ni $all} { set want [lindex $all 0] }
	set profile [expr {$want eq "" ? "" : $want}]
	_adopt
}
rio::openai::api::_adopt_settings
