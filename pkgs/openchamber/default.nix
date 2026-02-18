{
  lib,
  stdenv,
  fetchFromGitHub,
  bun,
  nodejs,
  opencode,
  python3,
  pkg-config,
  makeWrapper,
  vips,
  cacert,
}:

let
  pname = "openchamber";
  version = "1.7.1";

  src = fetchFromGitHub {
    owner = "btriapitsyn";
    repo = "openchamber";
    rev = "v${version}";
    hash = "sha256-3hzZVvapbbQ5aU8bpOqdmT7UU5CFHajD71Z9buPJzjw=";
  };

  nodeModules = stdenv.mkDerivation {
    pname = "${pname}-node-modules";
    inherit version src;

    nativeBuildInputs = [
      bun
      python3
      pkg-config
    ];

    buildInputs = [
      vips
    ];

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = "sha256-9ZWJgvObMKwuUhB86ve1P9fEN7z5UUWSmv8b/+2qbFE=";

    # Required for bun to work in sandbox
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    # Prevent fixup from creating store references
    dontFixup = true;

    buildPhase = ''
      runHook preBuild

      export HOME="$TMPDIR/home"
      export XDG_CACHE_HOME="$TMPDIR/cache"
      export BUN_INSTALL="$TMPDIR/.bun"
      export BUN_TMPDIR="$TMPDIR"
      mkdir -p "$HOME" "$XDG_CACHE_HOME"

      echo "=== Running bun install at root ==="
      bun --version
      bun install 2>&1

      echo "=== Running bun install in packages/web ==="
      cd packages/web
      bun install 2>&1
      cd ../..

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out

      # Dereference symlinks during copy - bun uses symlinks for hoisted deps
      # that would break when moved to the nix store
      cp -rL node_modules/* $out/ 2>/dev/null || true

      # Copy packages/web/node_modules (non-hoisted deps) on top
      if [ -d packages/web/node_modules ]; then
        cp -rLn packages/web/node_modules/* $out/ 2>/dev/null || true
      fi

      runHook postInstall
    '';
  };
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    bun
    nodejs
    makeWrapper
  ];

  buildPhase = ''
    runHook preBuild

    cp -r ${nodeModules} node_modules
    chmod -R u+w node_modules

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/node_modules/@openchamber
    cp -r packages/web $out/lib/node_modules/@openchamber/web
    cp -rL node_modules/* $out/lib/node_modules/

    mkdir -p $out/bin
    ln -s $out/lib/node_modules/@openchamber/web/bin/cli.js $out/bin/openchamber-unwrapped
    makeWrapper $out/bin/openchamber-unwrapped $out/bin/openchamber \
      --prefix PATH : ${lib.makeBinPath [opencode]} \
      --set OPENCODE_BINARY ${lib.getExe opencode}

    runHook postInstall
  '';

  meta = with lib; {
    description = "Web and desktop interface for OpenCode AI agent";
    homepage = "https://github.com/btriapitsyn/openchamber";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.linux ++ platforms.darwin;
    mainProgram = "openchamber";
  };
}
