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
    outputHash = "sha256-KnOqfBbqoWKRdQIi+lYjGX6As3LbCl6gQ2zBvIVaMO0=";

    # Required for bun to work in sandbox
    HOME = "/tmp";
    XDG_CACHE_HOME = "/tmp/.cache";
    BUN_INSTALL = "/tmp/.bun";
    SSL_CERT_FILE = "${cacert}/etc/ssl/certs/ca-bundle.crt";

    # Allow network access for fixed-output derivation
    __noChroot = true;

    buildPhase = ''
      runHook preBuild

      echo "=== Running bun install ==="
      bun --version
      bun install --frozen-lockfile 2>&1 || bun install 2>&1

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      cp -r node_modules $out

      # Remove broken symlinks created by bun
      find $out -type l -exec test ! -e {} \; -delete

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
    cp -r node_modules $out/lib/node_modules/

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
