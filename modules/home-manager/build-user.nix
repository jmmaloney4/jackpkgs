# jackpkgs.build-user — minimal Home Manager config for a remote-build account
# (ADR-051). Promoted from garden `nixfiles/home/plato.nix`.
#
# The NixOS/nix-darwin side (`jackpkgs.build-user`, modules/common/build-user.nix)
# creates the account and enables this module for it; a consumer rarely imports
# it directly.
#
# The "Build Machine" git identity is not a person's identity: it is the fixed
# committer string of an account nobody logs into interactively, so it is baked
# rather than an option (ADR-051 Decision 4: no option for a value nobody varies).
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkForce mkIf mkMerge;
in {
  options.jackpkgs.build-user.enable = lib.mkEnableOption "the minimal build-user Home Manager profile (bash, git, gh)";

  config = mkIf config.jackpkgs.build-user.enable (mkMerge [
    {
      home.stateVersion = lib.mkDefault "24.05";

      programs.bash.enable = true;
      programs.git = {
        enable = true;
        settings.user = {
          name = "Build Machine";
          email = "build@localhost";
        };
      };

      programs.gh = {
        enable = true;
        settings.git_protocol = "ssh";
      };
    }
    (mkIf pkgs.stdenv.hostPlatform.isDarwin {
      home.homeDirectory = mkForce "/Users/${config.home.username}";
    })
    (mkIf pkgs.stdenv.hostPlatform.isLinux {
      home.homeDirectory = mkForce "/home/${config.home.username}";
    })
  ]);
}
