{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkOption types;
  root =
    if config ? jackpkgs && config.jackpkgs ? projectRoot
    then config.jackpkgs.projectRoot
    else inputs.self.outPath;
in {
  options.jackpkgs.projectRoot = mkOption {
    type = types.path;
    default = inputs.self.outPath;
    defaultText = "inputs.self.outPath";
    description = ''
      Absolute path to the consumer repository root. Defaults to the flake's self path.
      Other jackpkgs modules resolve relative project files against this location.
    '';
  };

  config.perSystem = {
    ...
  }: {
    _module.args.jackpkgsProjectRoot = root;
  };
}
