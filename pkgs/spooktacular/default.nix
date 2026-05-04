{
  lib,
  stdenvNoCC,
  git,
  cacert,
  # From nvfetcher
  src,
  version,
  date,
}:
# Spooktacular CLI ("spook") manages macOS virtual machines via
# Apple's Virtualization.framework.  It must be built with the system
# Swift compiler (/usr/bin/swift) because the Nix apple-sdk does not
# include Virtualization.framework and the SDK version mismatch causes
# compile errors.
#
# Strategy: fixed-output derivation to get network access (Swift PM
# clones dependencies at build time).  Uses the system Swift toolchain.
# nvfetcher tracks the source; outputHash must be updated manually when
# the source changes.  To update:
#   1. nix run nixpkgs#nvfetcher  (updates _sources/)
#   2. nix build .#spooktacular 2>&1 | grep "got:"
#   3. Replace outputHash below with the "got:" value

stdenvNoCC.mkDerivation {
  pname = "spooktacular";
  version = "0-unstable-${date}";

  inherit src;

  # Fixed-output derivation: Nix grants network access. The output hash
  # pins the binary content.
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
  outputHash = "sha256-v1IkcBBi7W/t8y3SqxeqmvyldH6gaDsskYFD++iJzqE=";

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
