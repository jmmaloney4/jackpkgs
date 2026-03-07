{ stdenv, lib }:
stdenv.mkDerivation {
  pname = "adr-conflict-check";
  version = "0.1.0";

  src = ./.;

  dontBuild = true;

  installPhase = ''
    install -Dm755 adr-conflict-check.sh $out/bin/adr-conflict-check
  '';

  meta = {
    description = "Check ADR directory for duplicate numbers, skipped numbers, and malformed filenames";
    mainProgram = "adr-conflict-check";
    platforms = lib.platforms.all;
  };
}
