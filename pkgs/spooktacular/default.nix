{
  lib,
  stdenv,
  git,
  cacert,
  fetchgit,
  # From nvfetcher
  src,
  version,
  date,
}:

# Spooktacular CLI ("spook") manages macOS virtual machines via
# Apple's Virtualization.framework.  Built with system Swift because
# the Nix apple-sdk lacks Virtualization.framework.
#
# Strategy: fixed-output derivation because macOS Nix build isolation
# prevents Swift PM from writing .build/ artifacts in a normal derivation.
# Dependencies are pre-fetched via swiftpm-deps.nix so no git clone happens
# at build time.  The FOD hash is impure against the system Swift version only.
#
# outputHash update workflow:
#   1. nix run nixpkgs#nvfetcher (updates _sources/)
#   2. If deps changed: regenerate swiftpm-deps.nix (see update-deps.sh)
#   3. nix build .#spooktacular 2>&1 | grep "got:"
#   4. Replace outputHash below with the "got:" value

let
  swiftpmDeps = import ./swiftpm-deps.nix { inherit fetchgit; };
in

stdenv.mkDerivation {
  pname = "spooktacular";
  version = "0-unstable-${date}";

  inherit src;

  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
  outputHash = "sha256-sy/zq0paozoBhV9N3W5dUZKfQfZOa+Oj3wAwNZ2FuME=";

  nativeBuildInputs = [ git ];

  SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
  GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";

  phases = [ "unpackPhase" "buildPhase" "installPhase" ];

  buildPhase = ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    # Symlink pre-fetched deps so swift package resolve is a no-op
    mkdir -p .build/checkouts
    ${lib.concatLines (lib.mapAttrsToList (name: drv: ''
      ln -s "${drv}" ".build/checkouts/${lib.escapeShellArg name}"
    '') swiftpmDeps)}

    unset SDKROOT DEVELOPER_DIR

    # Resolve from pre-fetched checkouts, then build
    /usr/bin/swift package resolve --disable-sandbox
    /usr/bin/swift build \
      -c release \
      --arch ${stdenv.hostPlatform.darwinArch} \
      --product spook \
      --disable-sandbox
  '';

  installPhase = ''
    mkdir -p "$out/bin"
    cp .build/release/spook "$out/bin/spook"
  '';

  meta = {
    description = "macOS virtual machine manager using Virtualization.framework";
    homepage = "https://github.com/Spooky-Labs/spooktacular";
    license = lib.licenses.mit;
    platforms = lib.platforms.darwin;
    mainProgram = "spook";
  };
}
