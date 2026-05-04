{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  git,
  cacert,
}:
# Spooktacular CLI ("spook") manages macOS virtual machines via
# Apple's Virtualization.framework.  It must be built with the system
# Swift compiler (/usr/bin/swift) because the Nix apple-sdk does not
# include Virtualization.framework and the SDK version mismatch causes
# compile errors.
#
# Strategy: fixed-output derivation to get network access (Swift PM
# clones dependencies at build time).  Uses the system Swift toolchain.
let
  version = "0.1.0-unstable-2026-04-19";
  srcHash = "sha256-x8bqwvbw0WZKASEIDqCVR8b91RqJKSLYcNSfe68WzrE=";
in
stdenvNoCC.mkDerivation {
  pname = "spooktacular";
  inherit version;

  src = fetchFromGitHub {
    owner = "Spooky-Labs";
    repo = "spooktacular";
    rev = "main";
    hash = srcHash;
  };

  # Fixed-output derivation: Nix grants network access. The output hash
  # pins the binary content.  To update after a new commit:
  #   1. Update version date above
  #   2. nix build .#spooktacular 2>&1 | grep "got:"
  #   3. Replace the hash below with the "got:" value
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
  outputHash = "sha256-t4J6Fw3TjsBJ4LYtNrXwMvslkxvVTRBJ4Dpz8tV/HNM=";

  nativeBuildInputs = [ git ];

  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  phases = [ "unpackPhase" "buildPhase" "installPhase" ];

  buildPhase = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    # Unset Nix SDK vars that conflict with system Swift
    unset SDKROOT DEVELOPER_DIR

    /usr/bin/swift build \
      -c release \
      --arch arm64 \
      --product spook \
      --disable-sandbox
  '';

  installPhase = ''
    mkdir -p "$out/bin"
    cp .build/release/spook "$out/bin/spook"
    chmod +x "$out/bin/spook"
  '';

  meta = {
    description = "macOS virtual machine manager using Virtualization.framework";
    homepage = "https://github.com/Spooky-Labs/spooktacular";
    license = lib.licenses.mit;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "spook";
  };
}
