# jackpkgs.nixbuild — nixbuild.net as a remote builder for the nix daemon
# (ADR-050 fleet glue).
#
# Promoted from garden `nixfiles/modules/common/nixbuild.nix` (garden#2074
# Part B PR 2). nixbuild.net is a public service, so its host key and region
# are baked, not options.
#
# Garden's copy deferred to the dormant `nix-remote-builders` framework when
# that was enabled (it then wrote /etc/nix/machines itself). That framework
# stays in garden (ADR-050 Decision 6), so this module now owns the
# nixbuild.net entries outright. `environment.etc.<name>.text` is
# `types.lines`, so a consumer adding its own builders to
# `environment.etc."nix/machines".text` appends to these lines rather than
# replacing them.
{
  config,
  lib,
  ...
}: let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.jackpkgs.nixbuild;
in {
  options.jackpkgs.nixbuild = {
    enable = mkEnableOption "nixbuild.net (eu region) as a remote builder for x86_64-linux and aarch64-linux";

    keyPath = mkOption {
      # A path *string*: the private key must not be copied into the store.
      type = types.strMatching "^/.*";
      default = "/etc/nix/nixbuild_key";
      description = "Absolute path to the private SSH key the nix daemon (root) uses to reach nixbuild.net.";
    };
  };

  config = mkIf cfg.enable {
    programs.ssh.knownHosts.nixbuild = {
      hostNames = ["eu.nixbuild.net"];
      publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPIQCZc54poJ8vqawd8TraNryQeJnvH1eLpIDgbiqymM";
    };

    programs.ssh.extraConfig = ''
      Host eu.nixbuild.net
        PubkeyAcceptedKeyTypes ssh-ed25519
        ServerAliveInterval 60
        IPQoS throughput

      Match Host eu.nixbuild.net User root
        IdentityFile ${cfg.keyPath}
    '';

    environment.etc."nix/machines".text = ''
      ssh://eu.nixbuild.net x86_64-linux - 100 1 big-parallel,benchmark
      ssh://eu.nixbuild.net aarch64-linux - 100 1 big-parallel,benchmark
    '';
  };
}
