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
}: let
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
      python3
      pkg-config
      makeWrapper
    ];

    buildInputs = [
      vips
    ];

    # bun2nix hook runs preBuildPhases automatically:
    #   1. bunSetInstallCacheDirPhase — copies bunDeps cache to temp dir
    #   2. bunNodeModulesInstallPhase — bun install --linker=isolated
    #   3. bunLifecycleScriptsPhase  — bun install (with scripts)
    # Then our custom buildPhase runs with node_modules/ ready.

    buildPhase = ''
      runHook preBuild

      bun run --cwd packages/web build

      # Build a manifest mapping every package symlink to its bun-packages name.
      # node_modules/<pkg> is a symlink → .bun/<pkg>@<ver>/node_modules/<pkg>
      # For scoped: node_modules/@scope/<pkg> → ../.bun/@scope/<pkg>@<ver>/node_modules/@scope/<pkg>
      #
      # We extract the <pkg>@<ver> (or @scope/<pkg>@<ver>) to link against bunDeps.
      _build_manifest() {
        local nm="$1" manifest="$2"

        # Unscoped packages
        for entry in "$nm"/*; do
          [ -L "$entry" ] || continue
          local name=$(basename "$entry")
          [[ "$name" == .* ]] && continue  # skip .bun, .cache, etc.
          [[ "$name" == @* ]] && continue  # skip scoped (handled below)
          local target=$(readlink "$entry")
          # target: .bun/express@5.2.1/node_modules/express
          if [[ "$target" =~ \.bun/([^/]+)/node_modules/ ]]; then
            echo "$name|''${BASH_REMATCH[1]}" >> "$manifest"
          fi
        done

        # Scoped packages (@scope/pkg)
        for scope_dir in "$nm"/@*/; do
          [ -d "$scope_dir" ] || continue
          local scope=$(basename "$scope_dir")
          for entry in "$scope_dir"*; do
            [ -L "$entry" ] || continue
            local pkg_name=$(basename "$entry")
            local target=$(readlink "$entry")
            # target: ../../.bun/@codemirror/autocomplete@6.20.0/node_modules/@codemirror/autocomplete
            # or:     ../.bun/@codemirror/autocomplete@6.20.0/node_modules/@codemirror/autocomplete
            if [[ "$target" =~ \.bun/([^/]+/[^/]+)/node_modules/ ]]; then
              echo "$scope/$pkg_name|''${BASH_REMATCH[1]}" >> "$manifest"
            fi
          done
        done
      }

      touch "$TMPDIR/root-manifest.txt" "$TMPDIR/web-manifest.txt"
      _build_manifest "node_modules" "$TMPDIR/root-manifest.txt"
      _build_manifest "packages/web/node_modules" "$TMPDIR/web-manifest.txt"

      echo "Root manifest: $(wc -l < "$TMPDIR/root-manifest.txt") entries"
      echo "Web manifest: $(wc -l < "$TMPDIR/web-manifest.txt") entries"

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall

      local dest="$out/lib/openchamber"

      # Copy runtime files from packages/web
      mkdir -p "$dest/packages/web"
      cp -r packages/web/dist       "$dest/packages/web/dist"
      cp -r packages/web/server     "$dest/packages/web/server"
      cp -r packages/web/bin        "$dest/packages/web/bin"
      cp -r packages/web/public     "$dest/packages/web/public"
      cp    packages/web/package.json "$dest/packages/web/package.json"

      # Create node_modules from manifests by symlinking to bunDeps/share/bun-packages/
      _link_from_manifest() {
        local manifest="$1" dest_nm="$2"
        mkdir -p "$dest_nm"

        while IFS='|' read -r name pkgver; do
          [ -n "$name" ] && [ -n "$pkgver" ] || continue

          # Strip +wyhash suffix bun adds for peer-dep variants
          local pkgver_clean="''${pkgver%%+*}"
          local src_pkg="${bunDeps}/share/bun-packages/$pkgver_clean"

          # For scoped packages, ensure @scope/ directory exists
          if [[ "$name" == */* ]]; then
            mkdir -p "$dest_nm/$(dirname "$name")"
          fi

          if [ -d "$src_pkg" ]; then
            ln -s "$src_pkg" "$dest_nm/$name"
          else
            echo "ERROR: $pkgver not found in bunDeps/share/bun-packages/"
            echo "This usually means bun.nix is out of sync with the lockfile."
            exit 1
          fi
        done < "$manifest"
      }

      _link_from_manifest "$TMPDIR/root-manifest.txt" "$dest/node_modules"
      _link_from_manifest "$TMPDIR/web-manifest.txt"  "$dest/packages/web/node_modules"

      echo "Linked $(find "$dest/node_modules" -maxdepth 2 -type l | wc -l) root node_modules"
      echo "Linked $(find "$dest/packages/web/node_modules" -maxdepth 2 -type l | wc -l) web node_modules"

      # Wrapper script
      mkdir -p "$out/bin"
      makeWrapper ${bun}/bin/bun "$out/bin/openchamber" \
        --add-flags "$dest/packages/web/bin/cli.js" \
        --prefix PATH : ${lib.makeBinPath [opencode bun nodejs]} \
        --set OPENCODE_BINARY ${lib.getExe opencode} \
        --set NODE_ENV production

      runHook postInstall
    '';

    meta = with lib; {
      description = "Web and desktop interface for OpenCode AI agent";
      homepage = "https://github.com/btriapitsyn/openchamber";
      license = licenses.mit;
      maintainers = [
        {
          github = "jmmaloney4";
          name = "Jack Maloney";
          email = "jmmaloney4@gmail.com";
        }
      ];
      platforms = platforms.linux ++ platforms.darwin;
      mainProgram = "openchamber";
    };
  }
