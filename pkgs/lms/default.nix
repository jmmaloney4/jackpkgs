{
  #   lib,
  # #   stdenv,
  buildNpmPackage,
  fetchFromGitHub,
  callPackage,
  openssh,
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
}: let
  #   inherit (darwin.apple_sdk.frameworks)
  # Carbon
  # CoreFoundation
  # ApplicationServices
  # OpenGL
  # ;
    lmstudio-js = fetchFromGitHub {
    owner = "lmstudio-ai";
    repo = "lmstudio.js";
    rev = "release-43-c6bb28b";
    fetchSubmodules = true;
    buildInputs = [
        openssh
    ];
    # sha256 = "sha256-KLptMinet43NLFHoA1k80w6C0BQcLOGJDEtcaUHAnC8=";
    };


#   src = fetchFromGitHub {
#     owner = "lmstudio-ai";
#     repo = "lms";
#     rev = "39af94c1c1ea6c8ab270b973e3a5001fe3a6a816";
#     sha256 = "sha256-KLptMinet43NLFHoA1k80w6C0BQcLOGJDEtcaUHAnC8=";
#   };

  npmDepsHash = "sha256-qX/2Wqd4QNSzyzu3a39mc88dKivECmNl1IGlxVSGIG0=";

#   lms-common-server = buildNpmPackage {
#     pname = "lms-common-server";
#     version = "0.3.31";
#     src = lmstudio-js;
#     npmRoot = "packages/lms-cli";
#     # npmDepsHash = "sha256-qX/2Wqd4QNSzyzu3a39mc88dKivECmNl1IGlxVSGIG0=";
#   };
in
  buildNpmPackage rec {
    pname = "lms";
    version = "0.3.31";
    src = lmstudio-js;
    npmRoot = "packages/lms-cli";
    # npmDepsHash = "sha256-qX/2Wqd4QNSzyzu3a39mc88dKivECmNl1IGlxVSGIG0=";
  }
