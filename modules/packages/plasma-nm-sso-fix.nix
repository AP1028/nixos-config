{
  lib,
  ...
}: let
  # ────────────────────────────────────────────────────────────────────────────
  # USC VPN (vpn.usc.edu, AnyConnect SSO) fix for the KDE plasma-nm dialog.
  #
  # Background (2026-08-30, fully debugged and verified):
  #
  # 1. plasma-nm's openconnect dialog embeds a QWebEngineView. The ASA sets
  #    the `acSamlv2Token` cookie on the cross-site 302 that leads to the
  #    final SSO URI (`saml_ac_login.html`). openconnect's
  #    `cstp_sso_detect_done()` only considers the cookies passed in the SAME
  #    `oc_webview_result` as the final URI, and QWebEngine emits
  #    `cookieAdded` asynchronously — so the token frequently arrived AFTER
  #    the final URI had been reported and openconnect submitted an EMPTY
  #    token (ASA error 109).
  #    → openconnectauth.cpp: cache cookies (latest value per name), wait up
  #      to 500 ms for pending cookie signals on URL changes, and attach the
  #      cached cookies to every openconnect_webview_load_changed() report.
  #
  # 2. Cisco STRAP: openconnect 9.12 registers X-AnyConnect-STRAP keys during
  #    the aggregate auth. The ASA then REJECTS the resulting session cookie
  #    from any new connection (401 "Cookie was rejected"), because the cookie
  #    only carries the signing key, not the registered DH key. The manual
  #    non-STRAP aggregate-auth flow produces a cookie that connects fine.
  #    → openconnect: new `openconnect_set_no_strap()` API (patched into
  #      openconnect-internal.h / openconnect.h / cstp.c / auth.c /
  #      library.c / libopenconnect.map.in) disables STRAP registration while
  #      keeping the SSO capability. plasma-nm's worker thread calls it.
  #
  # 3. NM secret flags: the connection profile must declare the dialog's
  #    generated secrets (cookie/gateway/gwcert/...) as AgentOwned, otherwise
  #    NM treats them as system-owned and, because the kded agent lacks the
  #    MODIFY_SYSTEM polkit permission, silently DISCARDS them
  #    ("agent failed to authenticate but provided system secrets" →
  #    "final secrets request failed to provide sufficient secrets").
  #    → see the `usc-vpn` profile setup in docs/usc-vpn-openconnect-sso.md.
  #
  # PINNING: both packages are pinned to the sources this fix was written and
  # verified against (nixpkgs rev 56c02bc00adcf003215cc4bd996d6efaf4cff188).
  # A `nix flake update` therefore does NOT silently pick up new upstream
  # openconnect/plasma-nm code and does not force a rebuild unless the
  # dependency closure changes. Bump the pins deliberately (below) and
  # re-verify the patches still apply and the connection still works.
  # ────────────────────────────────────────────────────────────────────────────

  # openconnect source pin: GitLab rev the no-strap patch applies to.
  openconnectRev = "0dcdff87db65daf692dc323732831391d595d98d";
  openconnectHash = "sha256-AvowUEDkXvR+QkhJbZU759fZjIqj/mO8HjP2Ka3lH1U=";

  # plasma-nm source pin: KDE release tarball the SSO fix applies to.
  plasmaNmVersion = "6.7.4";
  plasmaNmHash = "sha256-xNSeCAclEO0dLqnhJNz0k6hkWDkcdW0UqqwowsCn5IQ=";
in {
  nixpkgs.overlays = [
    (final: prev: {
      # Cisco STRAP: the ASA binds the session to STRAP keys registered during
      # auth and rejects the resulting session cookie from a new connection
      # (401). openconnect_set_no_strap() disables STRAP so the obtained
      # cookie works with plain `openconnect -C "webvpn=..."` (verified).
      openconnect = prev.openconnect.overrideAttrs (old: {
        # pinned source (see header comment); bump openconnectRev/openconnectHash
        src = prev.fetchFromGitLab {
          owner = "openconnect";
          repo = "openconnect";
          rev = openconnectRev;
          hash = openconnectHash;
        };
        patches = (old.patches or []) ++ [../../packages/openconnect-no-strap/openconnect-no-strap.patch];
      });
      kdePackages = prev.kdePackages // {
        plasma-nm = (prev.kdePackages.plasma-nm.override {
          # must re-resolve against the patched openconnect so the worker
          # sees openconnect_set_no_strap()
          openconnect = final.openconnect;
        }).overrideAttrs (old: {
          # pinned source (see header comment); bump plasmaNmVersion/plasmaNmHash
          version = plasmaNmVersion;
          src = prev.fetchurl {
            url = "mirror://kde/stable/plasma/${plasmaNmVersion}/plasma-nm-${plasmaNmVersion}.tar.xz";
            sha256 = plasmaNmHash;
          };
          patches = (old.patches or []) ++ [../../packages/plasma-nm-openconnect-sso/plasma-nm-openconnect-sso.patch];
        });
      };
    })
  ];
}
