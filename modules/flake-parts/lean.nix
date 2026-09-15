# `jackpkgs.lean` — Nix-built Lean 4 environments, one per checkout.
# See docs/internal/designs/049-lean-toolchain-module.md.
#
# The unit is a checkout. Everything is derived from the `lean-toolchain` and
# `lake-manifest.json` a Lean project already commits, so no pin is restated
# anywhere it could drift, and two projects that happen to agree on revisions
# share store paths because Nix keys on inputs — not because anyone named a
# shared environment.
{jackpkgsInputs}: {
  inputs,
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.lean;
  leanLib = import ../../lib/lean.nix {inherit lib;};
in {
  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.lean = {
      enable = mkEnableOption "jackpkgs-lean (Nix-built Lean 4 toolchains and dependency closures)" // {default = false;};
    };

    perSystem = mkDeferredModuleOption ({
      config,
      lib,
      pkgs,
      system,
      ...
    }: {
      options.jackpkgs.lean = {
        projects = mkOption {
          default = {};
          description = ''
            Lean projects to build environments for, keyed by output name.
            Each must be a checkout containing both `lean-toolchain` and a
            committed `lake-manifest.json`.
          '';
          type = types.attrsOf (types.submodule ({name, ...}: {
            options = {
              src = mkOption {
                type = types.path;
                description = ''
                  The Lean project checkout. Must contain `lean-toolchain` and
                  `lake-manifest.json`; the latter is the output of `lake update`,
                  which reaches the network and so cannot run inside a derivation.
                '';
              };

              artifactHash = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  Fixed-output hash of this project's fetched dependency
                  artifacts, for THIS system. `.olean` files are compiled, so
                  expect one hash per (revision, system) pair.

                  To obtain it, set this to `lib.fakeHash`, build
                  `packages.${name}-lean-deps`, and copy the hash Nix reports.
                '';
              };

              lakeTarget = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Lake target to build for `packages.<name>`. Null builds no project target, only the environment.";
              };
            };
          }));
        };
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      pkgs,
      lib,
      config,
      system,
      ...
    }: let
      # Resolve a checkout to its toolchain and dependency artifacts.
      #
      # Each environment instantiates its own nixpkgs: lean4-nix delivers a
      # toolchain as an overlay that REPLACES `pkgs.lean`, so one package set
      # can hold exactly one Lean. That cost is real, and it is the reason this
      # owns the instantiation rather than accepting a `pkgs` argument — a
      # caller has no way to supply a correct one.
      mkLeanEnv = {
        name,
        src,
        artifactHash,
      }: let
        tag = leanLib.readToolchainTag src;

        upstreamDir = "${jackpkgsInputs.lean4-nix}/manifests";

        manifest = leanLib.loadManifest {
          path = leanLib.resolveManifestPath {
            vendoredDir = ../../pkgs/lean4-toolchains;
            inherit upstreamDir tag;
          };
          inherit upstreamDir;
        };

        leanOverlay = final: prev: {
          lean =
            (final.callPackage "${jackpkgsInputs.lean4-nix}/lib/toolchain.nix" {
              stdenv =
                if prev.stdenv.hostPlatform.isDarwin
                then leanLib.dontFixupStdenv prev.stdenv
                else prev.stdenv;
            })
            .fetchBinaryLean
            manifest;
        };

        leanPkgs = import jackpkgsInputs.nixpkgs {
          inherit system;
          overlays = [leanOverlay];
        };

        toolchain = leanPkgs.lean.lean-all;

        manifestPath = "${src}/lake-manifest.json";

        # `lake exe cache get` fetches Mathlib CI's prebuilt artifacts for the
        # pinned revisions — immutable blobs, not a fresh computation — which is
        # exactly what a fixed-output derivation is for. Measured byte-identical
        # across independent runs, and independent of which modules the project
        # imports; see lib/lean.nix for the one exception this prunes.
        deps = leanPkgs.stdenv.mkDerivation {
          pname = "${name}-lean-deps";
          version = tag;
          inherit src;

          nativeBuildInputs = [toolchain leanPkgs.cacert leanPkgs.git leanPkgs.curl];

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          outputHash =
            if artifactHash != null
            then artifactHash
            else
              throw ''
                jackpkgs.lean: project ${builtins.toJSON name} has no artifactHash for ${system}.
                Set it to lib.fakeHash, build .#${name}-lean-deps, and copy the reported hash.
              '';

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            lake exe cache get
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp -R .lake/packages "$out/packages"
            chmod -R u+w "$out/packages"
            ${leanLib.pruneCacheToolArtifacts "$out/packages/mathlib/.lake/build"}
            runHook postInstall
          '';

          # The artifacts are Lean's, already consistent; nixpkgs' fixup would
          # only rewrite them (see lib/lean.nix on darwin Mach-O corruption).
          dontFixup = true;
        };

        devShell = leanPkgs.mkShell {
          name = "${name}-lean";
          packages = [toolchain leanPkgs.git];
          shellHook = ''
            echo "Lean ${tag} — dependency artifacts at ${deps}"
            echo "Link them in with: ln -sfn ${deps}/packages .lake/packages"
          '';
        };
      in {
        inherit tag toolchain deps devShell manifestPath;
      };

      envs = lib.mapAttrs (name: p:
        mkLeanEnv {
          inherit name;
          inherit (p) src artifactHash;
        })
      config.jackpkgs.lean.projects;
    in {
      packages = lib.mapAttrs' (name: env: lib.nameValuePair "${name}-lean-deps" env.deps) envs;
      devShells = lib.mapAttrs (name: env: env.devShell) envs;
    };
  };
}
