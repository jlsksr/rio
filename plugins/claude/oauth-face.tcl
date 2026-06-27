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
	# PROVISIONAL config — verified/corrected against the live flow in step 3.
	variable config [dict create \
		authorize_url     https://claude.ai/oauth/authorize \
		token_url         https://console.anthropic.com/v1/oauth/token \
		client_id         9d1c250a-e61b-44d9-88ed-5944d1962f5e \
		scope             "org:create_api_key user:profile user:inference" \
		messages_url      https://api.anthropic.com/v1/messages \
		anthropic_version 2023-06-01 \
		anthropic_beta    oauth-2025-04-20 \
		model             claude-sonnet-4-6 \
		max_tokens        4096 \
		secret_name       claude-oauth]

	# Network seams (real tcltls impls land in step 3; tests inject fakes).
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

# --- the OAuth sign-in flow --------------------------------------------------
# Kick off a browser sign-in. PKCE + a CSRF state, a one-shot loopback to catch
# the redirect, then the code->token exchange and a secret save. `on_done` is
# called with {ok true} or {ok false code .. message ..}. Returns the authorize
# URL (handy if the browser couldn't be launched and the user must open it).
proc rio::claude::oauth::sign_in {on_done} {
	set pk    [rio::oauth::pkce]
	set state [rio::oauth::random_token]
	set lp [rio::oauth::loopback_listen \
		[list rio::claude::oauth::_on_redirect $pk $state]]
	set redirect [dict get $lp redirect]
	set url [_authorize_url $redirect [dict get $pk challenge] $state]
	# Stash what the redirect handler will need (it only gets the query).
	variable pending
	set pending [dict create on_done $on_done redirect $redirect id [dict get $lp id]]
	if {![rio::oauth::browser_open $url]} {
		rio::oauth::loopback_cancel [dict get $lp id]
		{*}$on_done [dict create ok false code browser message \
			"Couldn't open a browser. Open this URL to sign in:\n$url"]
	}
	return $url
}

proc rio::claude::oauth::_on_redirect {pk state query} {
	variable pending
	set on_done [dict get $pending on_done]
	set redirect [dict get $pending redirect]
	if {![dict exists $query code] || [dict get $query code] eq ""} {
		set msg "Sign-in was cancelled or denied"
		catch {if {[dict exists $query error]} { set msg "Sign-in failed: [dict get $query error]" }}
		{*}$on_done [dict create ok false code denied message $msg]
		return
	}
	if {[dict exists $query state] && [dict get $query state] ne $state} {
		{*}$on_done [dict create ok false code state_mismatch message \
			"Sign-in state didn't match (possible interference) — please retry"]
		return
	}
	_exchange [dict get $query code] [dict get $pk verifier] $redirect $on_done
}

# Exchange the authorization code for tokens, then persist them as a secret.
proc rio::claude::oauth::_exchange {code verifier redirect on_done} {
	variable config
	variable token_transport
	set body [_form [dict create \
		grant_type    authorization_code \
		code          $code \
		redirect_uri  $redirect \
		client_id     [dict get $config client_id] \
		code_verifier $verifier]]
	set req [dict create \
		url     [dict get $config token_url] \
		headers [list Content-Type application/x-www-form-urlencoded] \
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
proc rio::claude::oauth::_authorize_url {redirect challenge state} {
	variable config
	set q [_form [dict create \
		response_type         code \
		client_id             [dict get $config client_id] \
		redirect_uri          $redirect \
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
