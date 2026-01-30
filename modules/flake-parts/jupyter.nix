{jackpkgsInputs}: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf mkEnableOption mkOption types;
  cfg = config.jackpkgs.jupyter;
in {
  imports = [
    jackpkgsInputs.jupyenv.flakeModule
  ];

  options = {
    jackpkgs.jupyter = {
      enable = mkEnableOption "jackpkgs-jupyter (jupyenv integration)";

      kernelEnv = mkOption {
        type = types.str;
        default = "default";
        description = "Name of the jackpkgs.python environment to use as the Python kernel.";
      };

      enableRust = mkOption {
        type = types.bool;
        default = false;
        description = "Enable Rust kernel (evcxr) using fenix.";
      };

      settings = mkOption {
        type = types.attrs;
        default = {
          port = 8888;
          token = "";
          password = "";
        };
        description = "JupyterLab server settings (passed to jupyterlab.settings).";
      };

      packageName = mkOption {
        type = types.str;
        default = "jupyter";
        description = "Name of the generated Jupyter package.";
      };
    };
  };

  config = mkIf cfg.enable {
    perSystem = {
      config,
      pkgs,
      inputs,
      system,
      ...
    }: let
      # Resolve Python environment
      pythonEnv = config.jackpkgs.outputs.pythonEnvironments.${cfg.kernelEnv};

      # Rust Kernel Setup
      # Reference: cavinsresearch/zeus nix/rust.nix
      rustKernel = let
        fenix = inputs.fenix.packages.${system};
        # Use stable toolchain
        toolchain = fenix.stable.toolchain;

        # Darwin fix for cargo/OpenSSL linkage (adapted from zeus)
        # On macOS, we need to ensure cargo uses the nixpkgs libcurl/openssl
        # instead of the system one to avoid dyld errors.
        cargo =
          if pkgs.stdenv.isDarwin
          then
            pkgs.runCommand "cargo-patched" {
              nativeBuildInputs = [pkgs.darwin.cctools]; # for install_name_tool
            } ''
              mkdir -p $out/bin
              cp ${toolchain}/bin/cargo $out/bin/cargo
              chmod +w $out/bin/cargo
              install_name_tool -change /usr/lib/libcurl.4.dylib ${pkgs.curl.out}/lib/libcurl.4.dylib $out/bin/cargo
              chmod -w $out/bin/cargo
            ''
          else toolchain;
      in {
        default = true;
        name = "rust";
        displayName = "Rust (evcxr)";
        packages = [
          pkgs.evcxr
          cargo
          fenix.stable.rustc
          fenix.stable.rust-src
          fenix.stable.rust-std
        ];
      };
    in {
      # Critical: propagate pkgs to jupyenv to respect overlays (Issue #5)
      jupyenv.pkgs = pkgs;

      jupyenv.jupyterlab = {
        settings = cfg.settings;

        kernels = {
          python = {
            ${cfg.kernelEnv} = {
              displayName = "Python (${cfg.kernelEnv})";
              env = pythonEnv;
            };
          };
        };
      };

      jupyenv.jupyterlab.kernels.rust = mkIf cfg.enableRust {
        evcxr = rustKernel;
      };

      # Set package name
      jupyenv.packageName = cfg.packageName;

      # Expose in devShell
      jackpkgs.shell.packages = [
        config.packages.${cfg.packageName}
      ];
    };
  };
}
