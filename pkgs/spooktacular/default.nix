{
  lib,
  stdenv,
  git,
  cacert,
  fetchgit,
  # From nvfetcher
  src,
  date,
}:
# Spooktacular CLI ("spook") manages macOS virtual machines via
# Apple's Virtualization.framework.  Built with system Swift because
# upstream requires swift-tools-version: 6.0 and nixpkgs ships 5.10.1.
# See garden ADR 059 for the full packaging context.
#
# Strategy: fixed-output derivation because macOS Nix build isolation
# prevents Swift PM from writing .build/ artifacts in a normal derivation.
# Dependencies are pre-fetched via swiftpm-deps.nix so no git clone happens
# at build time.  The FOD hash is impure against the system Swift version
# -- it will drift whenever hermione's Xcode CLI tools update.
#
# IMPORTANT: The binary is codesigned with SpookCLI.entitlements from the
# source tree.  Without the com.apple.security.virtualization entitlement,
# Virtualization.framework XPC services reject the binary at runtime with
# "Unable to connect to installation service" (VZErrorDomain 10004).
#
# outputHash update workflow:
#   1. nix run nixpkgs#nvfetcher (updates _sources/)
#   2. If deps changed: regenerate swiftpm-deps.nix (see update-deps.sh)
#   3. nix build .#spooktacular 2>&1 | grep "got:"
#   4. Replace outputHash below with the "got:" value
let
  swiftpmDeps = import ./swiftpm-deps.nix {inherit fetchgit;};
in
  stdenv.mkDerivation {
    pname = "spooktacular";
    version = "0-unstable-${date}";

    inherit src;

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = "sha256-S5Q7Ds7FG865ZMJNDIpGZ9G8lakyUuKd9OdMCdBERUw=";

    nativeBuildInputs = [git];

    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";
    GIT_SSL_CAINFO = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    phases = ["unpackPhase" "buildPhase" "installPhase"];

    buildPhase = ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"

      # Symlink pre-fetched deps so swift package resolve is a no-op
      mkdir -p .build/checkouts
      # Dep names are Swift PM package identities (alphanumeric + hyphens only)
      ${lib.concatLines (lib.mapAttrsToList (name: drv: ''
          ln -s "${drv}" ".build/checkouts/${name}"
        '')
        swiftpmDeps)}

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

      # Codesign with Virtualization.framework entitlements.
      # Uses a custom entitlements file that drops com.apple.security.app-sandbox.
      # The upstream SpookCLI.entitlements includes sandbox for App Store distribution,
      # but adhoc-signed binaries with that entitlement hit SIGTRAP because macOS
      # enforces the sandbox too aggressively for CLI usage.
      /usr/bin/codesign \
        --entitlements ${./spook-entitlements.plist} \
        --force \
        -s - \
        "$out/bin/spook"
    '';

    meta = {
      description = "macOS virtual machine manager using Virtualization.framework";
      homepage = "https://github.com/Spooky-Labs/spooktacular";
      license = lib.licenses.mit;
      platforms = lib.platforms.darwin;
      mainProgram = "spook";
    };
  }
