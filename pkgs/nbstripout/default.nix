{
  lib,
  stdenv,
  python3,
  fetchPypi,
  fetchFromGitHub,
  coreutils,
  gitMinimal,
  mercurial,
}:
stdenv.mkDerivation rec {
  version = "0.8.1";
  pname = "nbstripout";

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-6qyLa05yno3+Hl3ywPi6RKvFoXplRI8EgBQfgL4jC7E=";
  };

  testAssets = fetchFromGitHub {
    owner = "kynan";
    repo = "nbstripout";
    rev = "${version}";
    hash = "sha256-OSJLrWkYQIhcdyofS3Bo39ppsU6K3A4546UKB8Q1GGg=";
  };

  nativeBuildInputs = [
    python3
    python3.pkgs.pip
    python3.pkgs.setuptools
    python3.pkgs.wheel
  ];

  buildInputs = [
    python3
  ];

  nativeCheckInputs = [
    coreutils
    gitMinimal
    mercurial
    python3.pkgs.pytest
  ];

  buildPhase = ''
    runHook preBuild

    # Create a Python environment in our output
    export PYTHONPATH="$out/lib/${python3.libPrefix}/site-packages:$PYTHONPATH"
    mkdir -p "$out/lib/${python3.libPrefix}/site-packages"

    # Install nbformat and its dependencies
    # We need to install with deps to get all transitive dependencies
    python -m pip install --prefix="$out" --no-build-isolation nbformat==${python3.pkgs.nbformat.version}

    # Install nbstripout with no deps since we already have nbformat
    python -m pip install --prefix="$out" --no-deps --no-build-isolation "$src"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # The pip install above already puts everything in the right place
    # Just ensure the binary is executable
    chmod +x "$out/bin/nbstripout"

    runHook postInstall
  '';

  checkPhase = ''
    runHook preCheck

    export HOME=$(mktemp -d)
    export PATH="$out/bin:$PATH"
    export PYTHONPATH="$out/lib/${python3.libPrefix}/site-packages:$PYTHONPATH"
    git config --global init.defaultBranch main

    cp -r --no-preserve=mode,ownership ${testAssets}/tests/e2e_notebooks $TMPDIR/e2e_notebooks
    chmod -R +w $TMPDIR/e2e_notebooks

    # Test basic functionality
    python -c "import nbstripout; print('nbstripout import successful')"

    # Test the executable works
    nbstripout --help

    runHook postCheck
  '';

  doCheck = true;

  # No propagatedBuildInputs - this is the key to avoiding PATH pollution
  propagatedBuildInputs = [];

  meta = {
    description = "Strip output from Jupyter and IPython notebooks";
    homepage = "https://github.com/kynan/nbstripout";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [jluttine];
    mainProgram = "nbstripout";
  };
}
