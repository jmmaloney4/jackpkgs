{
#   lib,
# #   stdenv,
  buildNpmPackage,
  fetchFromGitHub,
#   copyDesktopItems,
#   makeDesktopItem,
#   makeWrapper,
#   libpng,
#   libX11,
#   libXi,
#   libXtst,
#   zlib,
#   darwin,
#   electron,
}:let
#   inherit (darwin.apple_sdk.frameworks)
    # Carbon
    # CoreFoundation
    # ApplicationServices
    # OpenGL
    # ;
in
buildNpmPackage rec { 
  pname = "lms";
  version = "0.3.31";
  src = fetchFromGitHub {
    owner = "lmstudio-ai";
    repo = "lms";
    rev = "39af94c1c1ea6c8ab270b973e3a5001fe3a6a816";
    sha256 = "sha256-KLptMinet43NLFHoA1k80w6C0BQcLOGJDEtcaUHAnC8=";
  };

  npmDepsHash = "sha256-qX/2Wqd4QNSzyzu3a39mc88dKivECmNl1IGlxVSGIG0=";
}
