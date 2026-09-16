# `jackpkgs.lean` — Nix-built Lean 4 environments, one per checkout.
# See docs/internal/designs/049-lean-toolchain-module.md.
#
# The unit is a checkout. Everything is derived from the `lean-toolchain` and
# `lake-manifest.json` a Lean project already commits, so no pin is restated
# anywhere it could drift.
{jackpkgsInputs}: {
  config,
  lib,
  ...
}: let
  inherit (lib) mkIf;
  cfg = config.jackpkgs.lean;
  leanLib = import ../../lib/lean.nix {inherit lib;};
in {
  # The maintenance recipe that regenerates pkgs/lean4-toolchains/, which the
  # refusal in lib/lean.nix:resolveManifestPath names as the fix. Kept in its
  # own file so the module and the recipe can be reviewed separately.
  imports = [(import ./lean-recipes.nix {inherit jackpkgsInputs;})];

  options = let
    inherit (lib) types mkOption mkEnableOption;
    inherit (jackpkgsInputs.flake-parts.lib) mkDeferredModuleOption;
  in {
    jackpkgs.lean = {
      enable = mkEnableOption "jackpkgs-lean (Nix-built Lean 4 toolchains and dependency closures)";
    };

    perSystem = mkDeferredModuleOption ({...}: {
      options.jackpkgs.lean = {
        projects = mkOption {
          default = {};
          description = ''
            Lean projects to build environments for, keyed by output name. Each
            must be a checkout containing both `lean-toolchain` and a committed
            `lake-manifest.json`.
          '';
          type = types.attrsOf (types.submodule {
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
                  Fixed-output hash of this project's fetched Mathlib artifacts,
                  for THIS system. `.olean` files are compiled, so expect one
                  hash per (revision, system) pair.

                  Only consulted for projects that depend on Mathlib — nothing
                  else has a public artifact cache, so everything else is built
                  from source and needs no hash.

                  Leave `null` to get a toolchain-only devShell that can mint the
                  hash: enter it, run `lake exe cache get`, then set this to
                  `lib.fakeHash` and build `.#<name>-lean-deps` to be told the
                  real value. A null hash MUST NOT break evaluation of unrelated
                  outputs, so the refusal lands at build time, not here.
                '';
              };
            };
          });
        };
      };
    });
  };

  config = mkIf cfg.enable {
    perSystem = {
      lib,
      config,
      system,
      ...
    }: let
      mkLeanEnv = {
        name,
        src,
        artifactHash,
      }: let
        tag = leanLib.readToolchainTag src;
        lakeManifest = leanLib.readLakeManifest src;
        depNames = leanLib.lakeManifestPackages lakeManifest;
        usesMathlib = leanLib.hasMathlib lakeManifest;

        upstreamDir = "${jackpkgsInputs.lean4-nix}/manifests";
        manifest = leanLib.loadManifest {
          path = leanLib.resolveManifestPath {
            vendoredDir = ../../pkgs/lean4-toolchains;
            inherit upstreamDir tag;
          };
          inherit upstreamDir tag;
        };

        # Upstream's own `readBinaryToolchain` is `(overlay final prev) // { lean = …; }`.
        # Applying the manifest's `overlay` is not optional: for every manifest
        # from v4.19.0 on it is where the pinned `cadical` comes from, and
        # dropping it surfaces much later as `could not execute external process
        # 'cadical'` inside a `bv_decide` proof.
        leanOverlay = final: prev:
          (manifest.overlay or (_: _: {}) final prev)
          // {
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

        # lean4-nix delivers a toolchain as an overlay that REPLACES `pkgs.lean`,
        # so one package set holds exactly one Lean. Hence a package set per
        # toolchain — and hence this owns the instantiation, since a caller has
        # no way to supply a correct one.
        leanPkgs = import jackpkgsInputs.nixpkgs {
          inherit system;
          overlays = [leanOverlay];
        };

        toolchain = leanPkgs.lean.lean-all;
        lake2nix = leanPkgs.callPackage "${jackpkgsInputs.lean4-nix}/lib/lake.nix" {
          lean = leanPkgs.lean;
        };

        # A developer's `.lake/` is multi-gigabyte and machine-specific; copying
        # it into the store would both bloat the closure and let local artifacts
        # perturb a fixed-output hash.
        cleanSrc = lib.cleanSourceWith {
          inherit src;
          name = "${name}-lean-src";
          filter = path: _: let
            base = baseNameOf path;
          in
            base != ".lake" && base != ".git" && !(lib.hasPrefix "result" base);
        };

        # A fixed-output derivation's store path is a function of (name, hash)
        # ONLY — not of `src`, and not of the manifest. Without the manifest's
        # digest in the name, bumping a dependency while keeping `artifactHash`
        # silently reuses the previous closure forever, and a stale Mathlib
        # yields *successful* builds against the wrong library.
        manifestDigest =
          lib.substring 0 12
          (builtins.hashString "sha256" (builtins.readFile "${toString src}/lake-manifest.json"));

        # Mathlib is the only Lean package with a public artifact cache, so
        # acquisition genuinely has two regimes.
        mathlibDeps = leanPkgs.stdenv.mkDerivation {
          pname = "${name}-lean-deps";
          version = "${tag}-${manifestDigest}";
          src = cleanSrc;

          nativeBuildInputs = [toolchain leanPkgs.cacert leanPkgs.git leanPkgs.curl];

          outputHashMode = "recursive";
          outputHashAlgo = "sha256";
          # `lib.fakeHash` is a placeholder, not a fallback: with no hash
          # recorded the build below refuses before fetching anything, so this
          # never silently produces an artifact.
          outputHash =
            if artifactHash != null
            then artifactHash
            else lib.fakeHash;

          buildPhase = ''
            runHook preBuild
            ${lib.optionalString (artifactHash == null) ''
              echo "jackpkgs.lean: project ${name} has no artifactHash for ${system}." >&2
              echo "Set it to lib.fakeHash and rebuild to be told the real value." >&2
              exit 1
            ''}
            # `sandbox = false` on darwin, so without this the build reads the
            # developer's ~/.cache/mathlib and mints a hash no other machine can
            # reproduce. Load-bearing, not hygiene.
            export HOME="$TMPDIR"
            lake exe cache get
            runHook postBuild
          '';

          # Measured: a fixed output over a raw `.lake/packages` is NOT
          # reproducible. See lib/lean.nix:pruneNondeterministic.
          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp -R .lake/packages "$out/packages"
            chmod -R u+w "$out/packages"
            ${leanLib.pruneNondeterministic "\"$out/packages\""}
            runHook postInstall
          '';

          dontFixup = true;
        };

        # Everything else: no cache exists, so build from source. Cheap in
        # practice — these dependency sets are small next to Mathlib's.
        sourceDeps = lake2nix.buildDeps {src = cleanSrc;};

        # The two regimes have different shapes — one tree versus one derivation
        # per dependency — so LEAN_PATH is computed from each rather than forcing
        # a unifying copy of several gigabytes.
        leanPathEntries =
          if usesMathlib
          then map (n: "${mathlibDeps}/packages/${n}/.lake/build/lib/lean") depNames
          else
            map (n: "${sourceDeps.${n}}/.lake/build/lib/lean")
            (builtins.filter (n: sourceDeps ? ${n}) depNames);

        depsDrv =
          if usesMathlib
          then mathlibDeps
          else
            leanPkgs.linkFarm "${name}-lean-deps" (lib.mapAttrsToList (n: d: {
                name = "packages/${n}";
                path = d;
              })
              sourceDeps);

        # With no hash there is nothing to point LEAN_PATH at, so the shell is
        # toolchain-only rather than unevaluable. That is what makes minting the
        # first hash possible: the previous shape reached the refusal through
        # `shellHook`, so the shell you needed in order to obtain a hash could
        # not be entered without one.
        haveDeps = !usesMathlib || artifactHash != null;

        devShell = leanPkgs.mkShell ({
            name = "${name}-lean";
            packages = [toolchain leanPkgs.git];
          }
          // lib.optionalAttrs haveDeps {
            LEAN_PATH = lib.concatStringsSep ":" leanPathEntries;
          }
          // lib.optionalAttrs (!haveDeps) {
            shellHook = ''
              echo "jackpkgs.lean: ${name} has no artifactHash for ${system}." >&2
              echo "  1. lake exe cache get" >&2
              echo "  2. set artifactHash = lib.fakeHash, build .#${name}-lean-deps" >&2
              echo "  3. record the hash Nix reports" >&2
            '';
          });
      in {
        inherit tag toolchain devShell usesMathlib;
        deps = depsDrv;
      };

      envs = lib.mapAttrs (name: p:
        mkLeanEnv {
          inherit name;
          inherit (p) src artifactHash;
        })
      config.jackpkgs.lean.projects;
    in {
      packages = lib.mapAttrs' (name: env: lib.nameValuePair "${name}-lean-deps" env.deps) envs;
      devShells = lib.mapAttrs (_: env: env.devShell) envs;
    };
  };
}
