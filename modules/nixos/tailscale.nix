# NixOS half of jackpkgs.tailscale. The option surface and the
# cross-platform config live in ../common/tailscale.nix.
{
  config,
  lib,
  pkgs,
  ...
}: {
  imports = [../common/tailscale.nix];

  # https://github.com/NixOS/nixpkgs/issues/180175 — NetworkManager-wait-online
  # times out while tailscale is up. Only patched when NetworkManager is
  # actually enabled: on systemd-networkd hosts (cluster nodes) the patched
  # unit would reference an nm-online that can never succeed and hang
  # activation.
  config = lib.mkIf (config.jackpkgs.tailscale.enable && config.networking.networkmanager.enable) {
    systemd.services.NetworkManager-wait-online.serviceConfig.ExecStart = [
      ""
      "${lib.getExe' pkgs.networkmanager "nm-online"} -q"
    ];
  };
}
