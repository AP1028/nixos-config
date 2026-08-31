# USC VPN (AnyConnect SSO) via NetworkManager + plasma-nm — full fix

Status: **working end-to-end** (verified 2026-08-30). Connects from the KDE
tray: click connect → SSO login page in the embedded webview → USC login +
Duo → tunnel up.

## Symptom (before the fix)

`nmcli connection up usc-vpn` or the KDE tray connect always failed after
completing SSO with:

```
Necessary secrets for the VPN connection 'usc-vpn' were not provided.
```

(journal: `vpn[...,"usc-vpn"]: final secrets request failed to provide
sufficient secrets`), even though the webview showed a successful login and
the dialog disappeared.

## Architecture — who does what

```
KDE tray / nmcli
  → NetworkManager (root) asks the secrets agent (kded6 / plasma-nm)
  → plasma-nm shows its openconnect auth dialog (embedded QWebEngineView)
      └─ libopenconnect (inside kded6) does the aggregate-auth + SSO:
         init → auth-request (sso-v2-login URL) → user logs in in the webview
         → acSamlv2Token cookie → <session-token> (= the webvpn cookie)
  → the dialog returns {cookie, gateway, gwcert} secrets to the agent
  → agent returns them to NetworkManager
  → nm-openconnect-service validates and runs the openconnect BINARY
     with -C "<cookie>" → tunnel up
```

There are two openconnect instances: the **dialog's embedded libopenconnect**
(auth inside kded6) and the **service's openconnect binary** (tunnel, run by
nm-openconnect-service as root).

## Root causes (three independent layers, all required)

### 1. QWebEngine cookie delivery is async (plasma-nm)

The ASA sets `acSamlv2Token` on the cross-site **302** that leads to the
final SSO URI (`+CSCOE+/saml_ac_login.html`). openconnect's
`cstp_sso_detect_done()` only looks at the cookies passed in the **same**
`oc_webview_result` as the final URI — and plasma-nm's `handleWebEngineUrl()`
passed an **empty** cookie array. The token arrives via
`QWebEngineCookieStore::cookieAdded`, which QWebEngine emits
asynchronously — frequently *after* the final URI was reported, so openconnect
submitted an **empty token** (ASA error 109).

Evidence (kded6 journal, instrumented build):

```
cookieAdded "acSamlv2Token" len= 24 cached= 44
load ".../saml_ac_login.html" status= 2
urlChanged ".../saml_ac_login.html" hasToken= true   ← after the fix
```

**Fix** (`packages/plasma-nm-openconnect-sso/plasma-nm-openconnect-sso.patch`,
applied via `modules/packages/plasma-nm-sso-fix.nix`):

- cache every cookie seen by the webview (latest value per name) in the
  widget;
- on every URL change, wait up to 500 ms for pending `cookieAdded` signals,
  then report the URL **with the cached cookies attached**, so the final-URI
  report carries `acSamlv2Token`.

### 2. Cisco STRAP binds the session to auth-time keys (openconnect)

openconnect 9.12 registers `X-AnyConnect-STRAP-*` keys during the aggregate
auth. The ASA then **rejects the resulting session cookie from any new
connection** (401, "Cookie was rejected by server"), because the cookie only
carries the signing key, not the registered DH key. The proven manual
non-STRAP aggregate-auth flow produces a cookie that connects fine.

Evidence: a fresh cookie from the dialog (obtained 30 s earlier) tested with
the binary:

```
openconnect -C "webvpn=<fresh token>" vpn.usc.edu
→ 401 Unauthorized / Cookie was rejected
```

while a session-token from the manual non-STRAP flow connected:

```
Got CONNECT response: HTTP/1.1 200 OK
CSTP connected. DPD 10, Keepalive 0
Configured as 10.48.138.2, with SSL connected and DTLS connected
```

**Fix** (`packages/openconnect-no-strap/openconnect-no-strap.patch`): new
`openconnect_set_no_strap(vpninfo, 1)` API that disables STRAP key
registration/headers while keeping the SSO capability; plasma-nm's worker
thread calls it. The resulting cookie is plain `webvpn=<token>` (no
`openconnect_strapkey=` prefix).

### 3. NM treats the dialog's fresh secrets as system-owned (profile)

The agent's returned secrets (cookie/gateway/gwcert) are only kept if they
are not system-owned **or** the agent passed the polkit MODIFY check. With an
empty `connection.permissions`, the profile is a *system* connection, the
check requires `settings.modify.system` (admin), the unprivileged kded agent
fails, and NM silently discards the secrets:

```
settings-connection: (vpn:...) agent failed to authenticate but provided system secrets
vpn[...,"usc-vpn"]: final secrets request failed to provide sufficient secrets
```

Making the connection user-owned does **not** work: the openconnect plugin
rejects private connections ("The 'openconnect' plugin doesn't support
private connections").

**Fix** (profile-level, applied with `nmcli`, see below): declare the secrets
the dialog generates as **AgentOwned** via `<name>-flags = 2` entries in
`vpn.data`. Then the MODIFY check is skipped entirely and the returned
secrets are accepted.

## Connection profile requirements (imperative, not in the repo)

The `usc-vpn` profile lives in
`/etc/NetworkManager/system-connections/usc-vpn.nmconnection` (root-only).
Required state:

- `vpn.data`: gateway, protocol, useragent **and** AgentOwned flags for every
  secret the dialog returns:

```console
nmcli connection modify usc-vpn \
  vpn.data "gateway=vpn.usc.edu, protocol=anyconnect, useragent=AnyConnect, \
            gateway-flags=2, cookie-flags=2, gwcert-flags=2, \
            autoconnect-flags=2, save_passwords-flags=2, \
            save_plaintext_cookies-flags=2, lasthost-flags=2"
```

  (`2` = NM_SETTING_SECRET_FLAG_AGENT_OWNED. Note: `nmcli connection modify
  usc-vpn vpn.data ...` **replaces** the whole dict — keep all keys.)

- `connection.permissions` must stay **empty** (system connection — the
  plugin rejects private connections).
- `vpn.secrets` may be empty; if stale secrets are stored, remove them
  (`nmcli connection modify usc-vpn vpn.secrets ""`).

## How to debug / verify

- Worker + widget logging (permanent, low-noise) in the user journal:

```console
journalctl --user -b | grep "plasma-nm openconnect"
# cookieAdded acSamlv2Token len=24  → token seen by the webview
# urlChanged .../saml_ac_login.html hasToken=true → token reached openconnect
# obtain_cookie ret=0 cookie=webvpn=... → auth succeeded, no strapkey prefix
# setting() secrets: cookie=62B/... → complete secrets returned
# secretagent: sending secrets: ...   → agent handed them to NM
```

- NM side (after `sudo nmcli general logging level DEBUG domain
  VPN,AGENTS,SETTINGS`): look for
  `agent failed to authenticate but provided system secrets` (missing
  `*-flags`) or `service indicated additional secrets required`.

- Manual non-STRAP flow (fallback that always worked):
  `openconnect -C "webvpn=<session-token>" vpn.usc.edu` with a session-token
  from the manual aggregate-auth script (`/tmp/opencode/usc-vpn-manual-flow.py`
  pattern: init → sso-v2-login URL → login in a browser → paste
  acSamlv2Token → submit as `<auth><sso-token>` → `<session-token>`).

## Bumping the pins

`modules/packages/plasma-nm-sso-fix.nix` pins:

- `openconnectRev` / `openconnectHash` — the GitLab source the no-strap patch
  applies to;
- `plasmaNmVersion` / `plasmaNmHash` — the KDE tarball the SSO fix applies to.

After `nix flake update`: these packages keep building from the pinned
sources (patches always apply; no rebuild unless the dependency closure
changes). Bump a pin only when it conflicts — e.g. the new nixpkgs requires a
newer openconnect, or the ASA's behavior needs a newer version — then
re-verify: `nixos-rebuild build`, connect from the tray, and confirm
`obtain_cookie ret=0` + `cookie=webvpn=...` in the user journal.
