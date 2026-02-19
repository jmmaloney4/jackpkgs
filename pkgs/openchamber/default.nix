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
  bun2nix-cli,
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
  bunDeps = bun2nix-cli.fetchBunDeps {
    bunNix = ./bun.nix;
  };
in
bun2nix-cli.mkDerivation {
  inherit pname version src bunDeps;

  nativeBuildInputs = [
    bun
    nodejs
    makeWrapper
    python3
    pkg-config
  ];

  buildInputs = [
    vips
  ];

  bunBuildFlags = [ "--cwd" "packages/web" "run" "build" ];

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    export NODE_ENV=production

    echo "=== Building frontend with Vite ==="
    bun run --cwd packages/web build 2>&1

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/node_modules/@openchamber
    cp -r packages/web $out/lib/node_modules/@openchamber/web

    # Copy root node_modules (includes .bun cache) to the expected location for workspace symlinks
    cp -r node_modules $out/lib/node_modules/

    # Fix symlinks in packages/web/node_modules that point to ../../node_modules/.bun
    # After copying to $out/lib/node_modules/@openchamber/web/node_modules,
    # the symlinks need one more level up to reach $out/lib/node_modules/.bun
    if [ -d "$out/lib/node_modules/@openchamber/web/node_modules" ]; then
      find "$out/lib/node_modules/@openchamber/web/node_modules" -type l -exec sh -c '
        for link; do
          target=$(readlink "$link")
          if [[ "$target" == *"../../node_modules/.bun"* ]]; then
            newtarget=$(echo "$target" | sed "s|../../node_modules/.bun|../../../node_modules/.bun|g")
            rm "$link"
            ln -s "$newtarget" "$link"
          fi
        done
      ' _ {} +
    fi

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
