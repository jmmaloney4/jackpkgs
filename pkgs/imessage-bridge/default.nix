{
  lib,
  stdenv,
  fetchFromGitHub,
  python3,
}:
stdenv.mkDerivation rec {
  pname = "imessage-bridge";
  version = "0.1.0";

  src = fetchFromGitHub {
    owner = "greghughespdx";
    repo = "imessage-bridge";
    rev = "v${version}";
    hash = "sha256-4RwXAoIqz7Xahwu30g9UW1+eNC6iyrd+F5vOs0Yu41E=";
  };

  nativeBuildInputs = [python3];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    cp bridge.py $out/bin/imessage-bridge
    chmod +x $out/bin/imessage-bridge
    patchShebangs $out/bin/imessage-bridge
    runHook postInstall
  '';

  meta = with lib; {
    description = "Zero-dependency HTTP bridge for macOS iMessage (chat.db + AppleScript)";
    homepage = "https://github.com/greghughespdx/imessage-bridge";
    license = licenses.mit;
    maintainers = [];
    platforms = platforms.darwin;
    mainProgram = "imessage-bridge";
  };
}
