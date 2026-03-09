{
  lib,
  stdenv,
  pythonPackage ? null,
  python312,
  fetchFromGitHub,
  rustPlatform,
  cargo,
  rustc,
  clang,
  uv,
  pkg-config,
  capnproto,
  # Build options
  version,
  rev,
  srcHash,
  cargoHash,
  buildMode ? "release",
  highPrecision ? true,
  cargoBuildTarget ? null,
  pyo3Only ? false,
  srcOverride ? null,
}: let
  python_ =
    if pythonPackage != null
    then pythonPackage
    else python312;
  effectiveSrc =
    if srcOverride != null
    then srcOverride
    else
      fetchFromGitHub {
        owner = "nautechsystems";
        repo = "nautilus_trader";
        inherit rev;
        hash = srcHash;
      };
in
  stdenv.mkDerivation {
    pname = "nautilus-trader";
    inherit version;

    src = effectiveSrc;

    cargoDeps = rustPlatform.fetchCargoVendor {
      src = effectiveSrc;
      name = "nautilus-trader-${version}-vendor";
      hash = cargoHash;
    };

    nativeBuildInputs = [
      rustPlatform.cargoSetupHook
      cargo
      rustc
      clang
      uv
      pkg-config
      capnproto
      python_
      python_.pkgs.poetry-core
      python_.pkgs.setuptools
      python_.pkgs.cython
      python_.pkgs.numpy
      python_.pkgs.packaging
    ];

    buildInputs = lib.optionals stdenv.isLinux [
      python_
    ];

    env =
      {
        BUILD_MODE = buildMode;
        PYO3_PYTHON = python_.interpreter;
        PYTHONHOME = python_;
        COPY_TO_SOURCE = "true";
        PARALLEL_BUILD = "true";
        HIGH_PRECISION =
          if highPrecision
          then "true"
          else "false";
      }
      // lib.optionalAttrs stdenv.isLinux {
        PYTHON_LIB_DIR = "${python_}/lib";
      }
      // lib.optionalAttrs (cargoBuildTarget != null) {
        CARGO_BUILD_TARGET = cargoBuildTarget;
      }
      // lib.optionalAttrs pyo3Only {
        PYO3_ONLY = "true";
      };

    preBuild =
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"

        export CC="${clang}/bin/clang"
        export CXX="${clang}/bin/clang++"
      ''
      + lib.optionalString stdenv.isLinux ''
        export LDSHARED="${clang}/bin/clang -shared"
        export LD_LIBRARY_PATH="${python_}/lib:''${LD_LIBRARY_PATH:-}"
      ''
      + lib.optionalString stdenv.isDarwin ''
        export RUSTFLAGS="''${RUSTFLAGS:+$RUSTFLAGS }-C link-arg=-undefined -C link-arg=dynamic_lookup"
        export LIBRARY_PATH="${python_}/lib:''${LIBRARY_PATH:-}"
        export LD_LIBRARY_PATH="${python_}/lib:''${LD_LIBRARY_PATH:-}"
        export DYLD_LIBRARY_PATH="${python_}/lib:''${DYLD_LIBRARY_PATH:-}"
      '';

    buildPhase = ''
      runHook preBuild
      uv build --wheel --no-build-isolation --out-dir dist --offline
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/dist"
      wheels=(dist/*.whl)
      if [ "''${#wheels[@]}" -eq 0 ]; then
        echo "No wheel produced in dist/" >&2
        ls -la dist >&2 || true
        exit 1
      fi
      cp "''${wheels[@]}" "$out/dist/"
      runHook postInstall
    '';

    meta = {
      description = "A high-performance algorithmic trading platform and event-driven backtester";
      homepage = "https://nautilustrader.io";
      license = lib.licenses.lgpl3Plus;
      platforms = lib.platforms.linux ++ lib.platforms.darwin;
      broken = false;
    };
  }
