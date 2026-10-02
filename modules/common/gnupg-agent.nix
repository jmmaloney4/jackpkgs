# jackpkgs.gnupg-agent — gpg-agent on, SSH support off (ADR-050 fleet glue).
# Promoted from garden `nixfiles/modules/common/gnupg-agent.nix`, which was
# unconditional; ADR-050 Decision 2 requires the enable flag.
{
  config,
  lib,
  ...
}: {
  options.jackpkgs.gnupg-agent.enable = lib.mkEnableOption "gpg-agent (without SSH agent support)";

  config = lib.mkIf config.jackpkgs.gnupg-agent.enable {
    programs.gnupg.agent = {
      enable = true;
      enableSSHSupport = false;
    };
  };
}
