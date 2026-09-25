{
  lib,
  stdenvNoCC,
  versionCheckHook,
  src,
  version,
}:
stdenvNoCC.mkDerivation {
  pname = "gawkbot";
  inherit src version;

  # goreleaser archives unpack to files in `.` (gawkbot, LICENSE, …), not a directory.
  sourceRoot = ".";

  nativeBuildInputs = [versionCheckHook];

  dontConfigure = true;
  dontBuild = true;
  # Statically linked Go binary; shrink path / patchelf of .dynamic is a no-op.
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall
    install -Dm755 gawkbot $out/bin/gawkbot
    install -Dm644 LICENSE $out/share/doc/gawkbot/LICENSE
    runHook postInstall
  '';

  doInstallCheck = true;
  versionCheckProgramArg = "--version";
  preInstallCheck = ''
    export HOME=$(mktemp -d)
  '';

  meta = {
    description = "WhatsApp-first CRM with an embedded web UI (prebuilt gawkbot binary)";
    homepage = "https://gawk.bot";
    license = lib.licenses.sustainableUse;
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "x86_64-darwin"
      "aarch64-darwin"
    ];
    mainProgram = "gawkbot";
  };
}
