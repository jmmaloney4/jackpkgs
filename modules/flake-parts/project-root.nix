{jackpkgsInputs}: {
  inputs,
  lib,
  ...
}: {
  options.jackpkgs.projectRoot = lib.mkOption {
    type = lib.types.path;
    default = inputs.self.outPath;
    defaultText = "inputs.self.outPath";
    description = ''
      Absolute path to the consumer repository root. Defaults to the flake's self path.
      Other jackpkgs modules resolve relative project files against this location.
    '';
  };

  config.perSystem = {config, ...}: {
    _module.args.jackpkgsProjectRoot = config.jackpkgs.projectRoot;
  };
}
