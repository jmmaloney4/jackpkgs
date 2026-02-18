{
  lib,
  stdenv,
  fetchurl,
  nodejs,
  python3,
  pkg-config,
  vips,
}:

let
  pname = "openchamber";
  version = "1.7.1";

  src = fetchurl {
    url = "https://registry.npmjs.org/@openchamber/web/-/web-${version}.tgz";
    hash = "sha256-gMBXaFSLInxXCPOW5tDN7BrVUZWEb/WrTTum9YmFMks=";
  };

  nodeModules = stdenv.mkDerivation {
    pname = "${pname}-node-modules";
    inherit version src;

    nativeBuildInputs = [
      nodejs
      python3
      pkg-config
    ];

    buildInputs = [
      vips
    ];

    impureEnvVars = lib.fetchers.proxyImpureEnvVars;

    outputHashAlgo = "sha256";
    outputHashMode = "recursive";
    outputHash = lib.fakeHash;

    buildPhase = ''
      runHook preBuild

      export npm_config_nodedir=${nodejs}
      export HOME=$(mktemp -d)

      npm install --ignore-scripts --nodedir=${nodejs}
      npm rebuild --nodedir=${nodejs}

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      cp -r node_modules $out

      runHook postInstall
    '';
  };
in
stdenv.mkDerivation {
  inherit pname version src;

  nativeBuildInputs = [
    nodejs
  ];

  buildPhase = ''
    runHook preBuild

    cp -r ${nodeModules} node_modules
    chmod -R u+w node_modules

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib/node_modules/@openchamber/web
    cp -r . $out/lib/node_modules/@openchamber/web/

    mkdir -p $out/bin
    ln -s $out/lib/node_modules/@openchamber/web/bin/cli.js $out/bin/openchamber

    runHook postInstall
  '';

  meta = with lib; {
    description = "Web and desktop interface for OpenCode AI agent";
    homepage = "https://github.com/btriapitsyn/openchamber";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.all;
    mainProgram = "openchamber";
  };
}
