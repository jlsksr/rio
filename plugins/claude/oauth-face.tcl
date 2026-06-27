# plugins/claude — the claude-oauth face (AGENTS.md D26).
#
# The "unofficial / best-effort" Claude provider: it authenticates with the
# user's claude.ai SUBSCRIPTION via OAuth (browser sign-in), then drives the
# shared inference core (rio::claude::infer). It owns ONLY its auth strategy, a
# config block, and its provenance — the durable inference code is shared with
# the (later) claude-api face.
#
# Resilience (D26): every volatile detail — endpoints, client id, scopes, headers,
# model — lives in `config` as DATA, overridable at runtime, so an upstream change
# is a one-line edit, not a rebuild. Failures surface as classified agent.error
# events with an actionable next step. The provenance is honest: this rides the
# same flow Anthropic's own tools use, not a documented third-party API.
#
# Network is a SEAM (transport / token_transport), so the whole flow is testable
# offline; the real tcltls transports are wired in step 3, where the config
# values below are also VERIFIED against the live flow (they are provisional here
# precisely because they drift — that is why they are data).

package require json

namespace eval rio::claude::oauth {
	# Config-as-data, verified against the live Claude Code flow (step 3). Every
	# value here can drift, so it is DATA — a one-line edit, not a rebuild (D26).
	# The `system` prompt is the spoof the subscription-OAuth path REQUIRES: the
	# Messages API rejects an oat token unless the request identifies as Claude
	# Code. (Authorized by the user, eyes open — it likely runs against Anthropic's
	# ToS and may break/revoke without notice; that is what the resilience is for.)
	variable config [dict create \
		authorize_url     https://claude.ai/oauth/authorize \
		token_url         https://console.anthropic.com/v1/oauth/token \
		client_id         9d1c250a-e61b-44d9-88ed-5944d1962f5e \
		scope             "org:create_api_key user:profile user:inference" \
		redirect_uri      https://console.anthropic.com/oauth/code/callback \
		messages_url      https://api.anthropic.com/v1/messages \
		anthropic_version 2023-06-01 \
		anthropic_beta    oauth-2025-04-20 \
		system            "You are Claude Code, Anthropic's official CLI for Claude." \
		model             claude-sonnet-4-6 \
		max_tokens        4096 \
		secret_name       claude-oauth]

	variable pending {}   ;# in-flight sign-in: {state, verifier}

	# Network seams (real tcltls impls land later in step 3; tests inject fakes).
	variable transport       rio::claude::oauth::_http_transport
	variable token_transport rio::claude::oauth::_token_http
}

# Override one config key (a user setting, a test, or a step-3 correction).
proc rio::claude::oauth::configure {key val} {
	variable config
	dict set config $key $val
}
proc rio::claude::oauth::cget {key} {
	variable config
	return [dict get $config $key]
}

# --- the provider (agent contract: conversation tools post) ------------------
proc rio::claude::oauth::provider {conversation tools post} {
	variable config
	variable transport
	set tok [_access_token]
	if {$tok eq ""} {
		{*}$post error not_signed_in \
			"Not signed in to Claude — use View ▸ Sign in to Claude"
		return
	}
	# (Proactive token refresh near expiry is wired with the network in step 3.)
	set auth [list Authorization "Bearer $tok"]
	rio::claude::infer $config $conversation $auth $transport $post
}

# Whether a credential is on hand (the GUI shows Sign in / Sign out accordingly).
proc rio::claude::oauth::signed_in {} {
	variable config
	return [rio::secret::has [dict get $config secret_name]]
}

proc rio::claude::oauth::sign_out {} {
	variable config
	rio::secret::forget [dict get $config secret_name]
}

# The stored access token, or "" if not signed in.
proc rio::claude::oauth::_access_token {} {
	variable config
	set s [rio::secret::get [dict get $config secret_name]]
	return [expr {[dict exists $s access_token] ? [dict get $s access_token] : ""}]
}

# --- the OAuth sign-in flow (paste-a-code; verified for this client) ---------
# The verified Claude Code flow uses Anthropic's HOSTED callback (code=true): the
# browser lands on a page that shows a code, which the user pastes back. So
# sign-in is two steps. `sign_in` mints PKCE + a CSRF state, stashes them, opens
# the browser at the authorize URL, and returns that URL (so the GUI can show it
# if the browser didn't open). The user then pastes the code into
# `complete_sign_in`. (The generic loopback catcher in rio::oauth stays available
# for providers whose client allows a localhost redirect; this one does not.)
proc rio::claude::oauth::sign_in {} {
	variable pending
	set pk    [rio::oauth::pkce]
	set state [rio::oauth::random_token]
	set pending [dict create state $state verifier [dict get $pk verifier]]
	set url [_authorize_url [dict get $pk challenge] $state]
	rio::oauth::browser_open $url
	return $url
}

# Finish sign-in with the pasted code. The hosted callback returns it as
# `code#state`; we verify the state, exchange the code for tokens, and save the
# secret. `on_done` gets {ok true} or {ok false code .. message ..}.
proc rio::claude::oauth::complete_sign_in {pasted on_done} {
	variable pending
	if {![dict size $pending]} {
		{*}$on_done [dict create ok false code no_flow message \
			"Start sign-in first (View ▸ Sign in to Claude)"]
		return
	}
	lassign [split [string trim $pasted] "#"] code pstate
	set want [dict get $pending state]
	set verifier [dict get $pending verifier]
	set pending {}
	if {$code eq ""} {
		{*}$on_done [dict create ok false code denied message \
			"No code was pasted — sign-in was cancelled or denied"]
		return
	}
	if {$pstate ne "" && $pstate ne $want} {
		{*}$on_done [dict create ok false code state_mismatch message \
			"The pasted code's state didn't match — please retry sign-in"]
		return
	}
	_exchange $code $verifier $want $on_done
}

# Exchange the authorization code for tokens (a JSON POST — the verified Claude
# Code token endpoint uses application/json, not form-encoding), then persist.
proc rio::claude::oauth::_exchange {code verifier state on_done} {
	variable config
	variable token_transport
	set body [_json_obj [dict create \
		grant_type    authorization_code \
		code          $code \
		state         $state \
		client_id     [dict get $config client_id] \
		redirect_uri  [dict get $config redirect_uri] \
		code_verifier $verifier]]
	set req [dict create \
		url     [dict get $config token_url] \
		headers [list Content-Type application/json] \
		body    $body]
	{*}$token_transport $req [list rio::claude::oauth::_exchanged $on_done]
}

proc rio::claude::oauth::_exchanged {on_done status body} {
	variable config
	if {$status == 0} {
		{*}$on_done [dict create ok false code network message \
			"Couldn't reach Claude to finish signing in ($body)"]
		return
	}
	if {$status != 200} {
		{*}$on_done [dict create ok false code exchange message \
			"Sign-in token exchange failed (HTTP $status) — the sign-in flow may have changed"]
		return
	}
	if {[catch {json::json2dict $body} d] || ![dict exists $d access_token]} {
		{*}$on_done [dict create ok false code exchange message \
			"Sign-in returned a response rio didn't expect — the integration may need an update"]
		return
	}
	set expires_in [expr {[dict exists $d expires_in] ? [dict get $d expires_in] : 3600}]
	rio::secret::save [dict get $config secret_name] [dict create \
		access_token  [dict get $d access_token] \
		refresh_token [expr {[dict exists $d refresh_token] ? [dict get $d refresh_token] : ""}] \
		expires_at    [expr {[clock seconds] + $expires_in}]]
	{*}$on_done [dict create ok true]
}

# --- helpers -----------------------------------------------------------------
# `code=true` selects the hosted-callback "show the code" mode (the user pastes
# it back); the redirect_uri is the registered hosted callback from config.
proc rio::claude::oauth::_authorize_url {challenge state} {
	variable config
	set q [_form [dict create \
		code                  true \
		response_type         code \
		client_id             [dict get $config client_id] \
		redirect_uri          [dict get $config redirect_uri] \
		scope                 [dict get $config scope] \
		code_challenge        $challenge \
		code_challenge_method S256 \
		state                 $state]]
	return "[dict get $config authorize_url]?$q"
}

proc rio::claude::oauth::_form {d} {
	set parts {}
	dict for {k v} $d { lappend parts "[_urlenc $k]=[_urlenc $v]" }
	return [join $parts &]
}

# A flat JSON object of string values (the token exchange body). Reuses the
# inference core's JSON string escaper.
proc rio::claude::oauth::_json_obj {d} {
	set parts {}
	dict for {k v} $d { lappend parts "[rio::claude::_jstr $k]:[rio::claude::_jstr $v]" }
	return "{[join $parts ,]}"
}

proc rio::claude::oauth::_urlenc {s} {
	set out ""
	foreach ch [split $s ""] {
		if {[string match {[A-Za-z0-9._~-]} $ch]} {
			append out $ch
		} else {
			foreach b [split [encoding convertto utf-8 $ch] ""] {
				scan $b %c code
				append out [format %%%02X [expr {$code & 0xff}]]
			}
		}
	}
	return $out
}

# --- network seams: real tcltls implementations land in step 3 ---------------
proc rio::claude::oauth::_http_transport {req on_chunk on_done} {
	{*}$on_done 0 "the Claude HTTPS transport is not wired yet (step 3)"
}
proc rio::claude::oauth::_token_http {req on_result} {
	{*}$on_result 0 "the Claude token transport is not wired yet (step 3)"
}
