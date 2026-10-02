# jackpkgs.fonts — a fixed font set (ADR-050 fleet glue; taste, so the list
# itself is not an option). Promoted from garden `nixfiles/modules/common/fonts.nix`.
{
  config,
  lib,
  pkgs,
  ...
}: {
  options.jackpkgs.fonts.enable = lib.mkEnableOption "jackpkgs' font set (DaddyTimeMono Nerd Font, Fira Code, Source Serif Pro, iA Writer Duospace)";

  config = lib.mkIf config.jackpkgs.fonts.enable {
    fonts.packages = [
      pkgs.nerd-fonts.daddy-time-mono
      pkgs.fira-code
      pkgs.source-serif-pro
      pkgs.ia-writer-duospace
    ];
  };
}
