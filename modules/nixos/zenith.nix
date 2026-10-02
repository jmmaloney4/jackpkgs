# jackpkgs.zenith — zenith with exactly the capabilities it needs to read
# other users' processes, instead of running it as root.
#
# Promoted from garden `nixfiles/modules/nixos/security-wrappers.nix` (its
# only wrapper was zenith, so the module is named for what it does), which
# was unconditional; ADR-050 Decision 2 requires the enable flag.
#
# - cap_sys_ptrace: read process information from other users
# - cap_dac_read_search: bypass permission checks when reading /proc
#
# security.wrappers grants the capabilities at activation time on
# /run/wrappers/bin/zenith, so the store path stays unmodified and
# cacheable; a `zenith` shim on PATH points at the wrapper.
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.jackpkgs.zenith.enable = lib.mkEnableOption "zenith with cap_sys_ptrace/cap_dac_read_search via security.wrappers";

  config = lib.mkIf config.jackpkgs.zenith.enable {
    security.wrappers.zenith = {
      source = "${pkgs.zenith}/bin/zenith";
      capabilities = "cap_sys_ptrace,cap_dac_read_search=ep";
      owner = "root";
      group = "root";
    };

    environment.systemPackages = [
      (pkgs.writeShellScriptBin "zenith" ''
        exec /run/wrappers/bin/zenith "$@"
      '')
    ];
  };
}
