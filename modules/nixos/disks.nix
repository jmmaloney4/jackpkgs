# jackpkgs.disks — label-based default `/` (ext4, label `nixos`) and `/boot`
# (vfat, label `boot`) filesystems, for hosts installed with those labels.
# Hosts whose disks are managed elsewhere (disko, hardware-configuration.nix)
# leave it off.
#
# Promoted from garden `nixfiles/modules/nixos/disks.nix`; garden's
# `enableDefaults` is renamed `enable` (ADR-050 Decision 2: every module has
# an `enable` flag).
{
  config,
  lib,
  ...
}: {
  options.jackpkgs.disks.enable = lib.mkEnableOption "the label-based default `/` and `/boot` filesystems";

  config = lib.mkIf config.jackpkgs.disks.enable {
    fileSystems."/" = {
      label = "nixos";
      fsType = "ext4";
    };

    fileSystems."/boot" = {
      label = "boot";
      fsType = "vfat";
    };
  };
}
