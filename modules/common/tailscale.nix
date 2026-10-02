# jackpkgs.tailscale — tailscale on, plus optional Mullvad exit-node egress
# plumbing for a Cilium egress-gateway host (ADR-050 fleet glue).
#
# Promoted from garden `nixfiles/modules/common/tailscale.nix` (garden#2074
# Part B PR 2; design: garden ADR 127). Dropped at promotion:
#
#   * `key` — declared but read by nothing (garden hosts set it to "").
#   * `package` — nobody varied it, and it only reached the CLI on PATH and
#     the exit-node script, never the daemon, so setting it produced a CLI
#     and daemon at different versions. The module now reads
#     `services.tailscale.package`, the one knob both upstream modules
#     already own.
#   * garden's root `jmmaloney4.tailscale-domain` (malformed, and read by no
#     module) — ADR-050 Decision 4 planned to fix it into a required option,
#     but a required option nothing reads is a pass-through variable; it is
#     not minted until a module needs the tailnet domain.
#
# Platform-agnostic: the systemd units are guarded by `options ? systemd`, so
# the file stays importable from nix-darwin. NixOS-only glue lives in
# ../nixos/tailscale.nix, which imports this file.
{
  config,
  lib,
  options,
  pkgs,
  ...
}: let
  inherit (lib) concatMapStringsSep escapeShellArg mkEnableOption mkIf mkMerge mkOption optionalAttrs types;
  cfg = config.jackpkgs.tailscale;
  mullvadCfg = cfg.mullvad;

  # Route forwarded (egress-gateway) traffic through a Tailscale Mullvad exit
  # node while exempting everything else: configured source CIDRs (the k8s
  # pod CIDR on the Cilium egress-gateway node) and the host's own
  # locally-originated traffic.
  #
  # Rule ordering is load-bearing: tailscaled's exit-node catch-all lives at
  # priority 5270 (`from all lookup 52`), so the exemptions sit just ahead of
  # it. Egress-gateway traffic is unaffected because Cilium SNATs it to the
  # host's tailnet address *before* routing and it arrives as *forwarded*
  # packets — it matches no exemption and falls through into table 52 / the
  # tunnel.
  #
  # Host-originated traffic evaluates policy rules with `iif lo`
  # (prios 5204/5205): without this exemption the gateway host's own egress
  # (image pulls, nix substitutions, etcd snapshot sync) rides the exit node
  # — measured at ~84 KB/s vs ~6 MB/s direct. Every `lookup main` exemption
  # needs a tailnet-destined `lookup 52` companion at a higher-priority rule:
  # rule fall-through only happens when the table has NO route for the
  # destination, and main's default route catches everything — a bare
  # `iif lo lookup main` breaks host→tailnet (including tailnet SSH).
  #
  # The exemptions are a separate unit ordered Before=tailscaled.service:
  # tailscaled applies its *persisted* exit-node preference as soon as it
  # connects, so installing the rules first closes the boot-time window in
  # which unlabeled pods on the gateway would briefly ride the exit node.
  # Rules referencing table 52 are valid even while the table is empty.
  mullvadExemptionsScript = pkgs.writeShellScript "tailscale-mullvad-exemptions" ''
    set -euo pipefail
    ip=${pkgs.iproute2}/bin/ip

    # Idempotent: clear any prior exemption rules, then (re)install.
    while "$ip" rule del priority 5195 2>/dev/null; do :; done
    while "$ip" rule del priority 5200 2>/dev/null; do :; done
    while "$ip" rule del priority 5204 2>/dev/null; do :; done
    while "$ip" rule del priority 5205 2>/dev/null; do :; done
    ${concatMapStringsSep "\n" (cidr: ''
        "$ip" rule add from ${escapeShellArg cidr} to 100.64.0.0/10 lookup 52 priority 5195
        "$ip" rule add from ${escapeShellArg cidr} lookup main priority 5200
      '')
      mullvadCfg.exemptSourceCIDRs}
    "$ip" rule add iif lo to 100.64.0.0/10 lookup 52 priority 5204
    "$ip" rule add iif lo lookup main priority 5205
  '';

  mullvadExitNodeScript = pkgs.writeShellScript "tailscale-mullvad-exit-node" ''
    set -euo pipefail
    tailscale=${config.services.tailscale.package}/bin/tailscale

    for i in $(seq 1 30); do
      if "$tailscale" status >/dev/null 2>&1; then break; fi
      echo "waiting for tailscaled... ($i/30)"; sleep 2
    done
    if ! "$tailscale" status >/dev/null 2>&1; then
      echo "tailscaled not ready after 60s; not setting exit node" >&2
      exit 1
    fi

    exec "$tailscale" set \
      --exit-node=${escapeShellArg mullvadCfg.exitNode} \
      --exit-node-allow-lan-access=true
  '';
in {
  options.jackpkgs.tailscale = {
    enable = mkEnableOption "tailscale (services.tailscale plus its CLI on PATH)";

    mullvad = {
      enable = mkEnableOption ''
        a Tailscale Mullvad exit node on this host as the Cilium egress-gateway
        tunnel. Forwarded traffic rides the exit node; the host's own egress
        and `exemptSourceCIDRs` stay on the normal WAN path. NixOS only
        (systemd units)'';

      exitNode = mkOption {
        type = types.str;
        example = "us-chi-wg-301.mullvad.ts.net";
        description = ''
          Mullvad exit node to use. Required when `mullvad.enable` is set (no
          default — this is deployment topology). The host needs the `mullvad`
          node attribute granted in the tailnet policy.
        '';
      };

      exemptSourceCIDRs = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["10.42.0.0/16"];
        description = ''
          Source CIDRs whose internet egress must NOT ride the exit node. On
          the Cilium egress-gateway node this must contain the cluster pod
          CIDR — otherwise every pod scheduled on the host is swept into the
          tunnel by tailscaled's catch-all route, not just pods selected by
          the CiliumEgressGatewayPolicy.
        '';
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.tailscale.enable = true;
      environment.systemPackages = [config.services.tailscale.package];
    }

    (optionalAttrs (options ? systemd) {
      # PartOf: a tailscaled restart re-runs both units, re-asserting the
      # rules and the exit-node preference alongside the daemon lifecycle.
      systemd.services.tailscale-mullvad-exemptions = mkIf mullvadCfg.enable {
        description = "Egress routing exemptions for the Mullvad exit node";
        before = ["tailscaled.service"];
        partOf = ["tailscaled.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${mullvadExemptionsScript}";
        };
      };

      systemd.services.tailscale-mullvad-exit-node = mkIf mullvadCfg.enable {
        description = "Set Tailscale Mullvad exit node";
        after = ["tailscaled.service" "network-online.target" "tailscale-mullvad-exemptions.service"];
        wants = ["tailscaled.service" "network-online.target"];
        requires = ["tailscale-mullvad-exemptions.service"];
        partOf = ["tailscaled.service"];
        wantedBy = ["multi-user.target"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${mullvadExitNodeScript}";
        };
      };
    })

    # Refuse rather than silently ignore: on a platform without systemd the
    # exit-node units above cannot exist.
    {
      assertions = [
        {
          assertion = !mullvadCfg.enable || options ? systemd;
          message = "jackpkgs.tailscale.mullvad requires systemd (NixOS); it cannot be enabled on this platform.";
        }
      ];
    }
  ]);
}
