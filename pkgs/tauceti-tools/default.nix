{
  lib,
  python313Packages,
  # From nvfetcher
  src,
  version,
}:
# Shared Tau Ceti configuration and administration helpers. Consumed as a Python library by
# tauceti-progress, tauceti-review, and tauceti; upstream also ships a `tauceti-tools` CLI.
python313Packages.buildPythonApplication {
  pname = "tauceti-tools";
  inherit src version;

  pyproject = true;
  build-system = [python313Packages.hatchling];

  doCheck = false;

  meta = {
    description = "Shared configuration, CI, and administration for Tau Ceti projects";
    homepage = "https://github.com/TauCetiProject/TauCetiTools";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "tauceti-tools";
  };
}
