# Pure helpers behind `jackpkgs.lean` (see docs/internal/designs/049-lean-toolchain-module.md).
#
# A Lean project's environment is derived entirely from two files the checkout
# already commits — `lean-toolchain` and `lake-manifest.json` — so there is no
# second place to restate a pin and nothing that can drift from the project.
{lib}: rec {
  # Strip surrounding whitespace, including the trailing newline every
  # `lean-toolchain` carries.
  trim = s: let
    m = builtins.match "[[:space:]]*(.*[^[:space:]])?[[:space:]]*" s;
    v = builtins.head m;
  in
    if m == null || v == null
    then ""
    else v;

  # A `lean-toolchain` pin -> the bare version tag.
  #
  #   "leanprover/lean4:v4.34.0\n"  ->  "v4.34.0"
  #
  # Anything else throws. Lean toolchains can also name a local directory or a
  # git revision, and those forms cannot be resolved to a binary release, so
  # accepting them here would only defer the failure to a point where it reads
  # as a Nix bug rather than an unsupported pin.
  parseToolchain = text: let
    pinned = trim text;
    prefix = "leanprover/lean4:";
    tag = lib.removePrefix prefix pinned;
    # Guard the interpolation into a manifest path below: a pin like
    # `leanprover/lean4:../../etc/passwd` would otherwise be a traversal that
    # `pathExists`/`import` would honour.
    wellFormed = builtins.match "[A-Za-z0-9._-]+" tag != null;
  in
    if !(lib.hasPrefix prefix pinned)
    then
      throw ''
        jackpkgs.lean: unsupported lean-toolchain pin ${builtins.toJSON pinned}.
        Only `leanprover/lean4:<tag>` pins resolve to a binary toolchain.
      ''
    else if !wellFormed
    then
      throw ''
        jackpkgs.lean: malformed toolchain tag ${builtins.toJSON tag}.
        Expected characters in [A-Za-z0-9._-] only.
      ''
    else tag;

  readToolchainTag = src: let
    p = "${toString src}/lean-toolchain";
  in
    if builtins.pathExists p
    then parseToolchain (builtins.readFile p)
    else
      throw ''
        jackpkgs.lean: ${toString src} has no `lean-toolchain`.
        Every supported project pins its toolchain in that file.
      '';

  # Resolve a version tag to a toolchain manifest, preferring jackpkgs' own
  # vendored manifests over upstream lean4-nix's.
  #
  # Vendored wins deliberately: upstream cuts manifests per stable release, so a
  # version we fetched ourselves (a release candidate, or anything newer than
  # upstream has reached) must keep resolving to the same bytes after upstream
  # later adds its own.
  #
  # A tag in neither set is a hard error naming the recipe that fixes it. It
  # MUST NOT silently fall back to `readRev`, which would source-build the Lean
  # compiler on top of Mathlib — hours of work triggered by a missing file.
  resolveManifestPath = {
    vendoredDir,
    upstreamDir,
    tag,
  }: let
    vendored = "${toString vendoredDir}/${tag}.nix";
    upstream = "${toString upstreamDir}/${tag}.nix";
  in
    if builtins.pathExists vendored
    then vendored
    else if builtins.pathExists upstream
    then upstream
    else
      throw ''
        jackpkgs.lean: no toolchain manifest for ${tag}.

        Upstream lean4-nix ships manifests per stable release, so release
        candidates and anything newer than its latest tag will be missing.
        Vendor one:

            just lean-toolchain-fetch ${lib.removePrefix "v" tag}

        which writes pkgs/lean4-toolchains/${tag}.nix. Refusing rather than
        falling back to a source build of the Lean compiler.
      '';

  # Load a manifest, adapting the two shapes we have to deal with.
  #
  # Upstream lean4-nix manifests are plain attrsets that pull `overlay`,
  # `bootstrap` and `buildLeanPackage` from sibling files by relative path
  # (`inherit (import ./v4.32.0.nix) bootstrap;`). A vendored copy living in
  # this repo cannot resolve those, so ours are FUNCTIONS taking the upstream
  # manifests directory and inheriting from it explicitly. Both are supported,
  # and which one a tag uses is invisible to callers.
  #
  # Two invariants are checked here rather than trusted, because both failures
  # are silent and permanent: a manifest whose `tag` disagrees with the file it
  # is named after would build the wrong compiler for every project pinning
  # that version, forever, since vendored shadows upstream by design; and a
  # manifest with no `toolchain` attribute (upstream's v4.20.1 is one) would
  # otherwise surface as a bare `attribute 'toolchain' missing`.
  loadManifest = {
    path,
    upstreamDir,
    tag,
  }: let
    loaded = import path;
    m =
      if lib.isFunction loaded
      then loaded {upstream = toString upstreamDir;}
      else loaded;
  in
    if !(m ? toolchain)
    then
      throw ''
        jackpkgs.lean: manifest for ${tag} has no `toolchain` attribute, so it
        cannot supply a binary Lean. Vendor one instead:

            just lean-toolchain-fetch ${lib.removePrefix "v" tag}
      ''
    else if (m.tag or null) != tag
    then
      throw ''
        jackpkgs.lean: manifest at ${toString path} declares tag
        ${builtins.toJSON (m.tag or null)} but was resolved for ${builtins.toJSON tag}.
        A vendored manifest must agree with its filename.
      ''
    else m;

  # Read a project's committed `lake-manifest.json`.
  #
  # It is the output of `lake update`, which reaches the network and so cannot
  # run inside a derivation. Refusing here is the difference between a pinned
  # dependency set and lake resolving `require`s from the network at build time
  # — which, inside a fixed-output derivation, would freeze whatever the CDN
  # happened to serve into an artifact that then reproduces faithfully forever.
  readLakeManifest = src: let
    p = "${toString src}/lake-manifest.json";
  in
    if builtins.pathExists p
    then builtins.fromJSON (builtins.readFile p)
    else
      throw ''
        jackpkgs.lean: ${toString src} has no committed `lake-manifest.json`.

        Generate one with `lake update` in the checkout and commit it. It is not
        generated here on purpose: that would be an unpinned network fetch
        wearing a pinned interface.
      '';

  lakeManifestPackages = m: map (p: p.name or "") (m.packages or []);

  # Mathlib is the only Lean package with a public artifact cache.
  #
  # `cache` is an executable Mathlib itself ships, hash-rooted at `Mathlib`;
  # `lake exe cache get` in a project without it fails with
  # `error: unknown executable cache`, and every Reservoir build-cache probe for
  # non-Mathlib packages 404s today. So dependency acquisition genuinely has two
  # regimes, and pretending otherwise would make the module Mathlib-only while
  # claiming to be general.
  hasMathlib = m: builtins.elem "mathlib" (lakeManifestPackages m);

  # Canonicalise what `lake exe cache get` leaves behind, so the tree is both
  # reproducible AND accepted by Lake (ADR-052, "Spike 2 result").
  #
  # Measured 2026-09-15: a fixed-output derivation over a raw `.lake/packages`
  # is NOT reproducible — two cold builds gave different hashes. Re-measured
  # 2026-10-22 (darwin/aarch64 and linux/x86_64, two fetches each, diffed): the
  # ~8,700 module `.trace` files Mathlib's archives deliver are byte-identical
  # across fetches. What differs is only
  #   - `.git` (reflogs, pack names, index mtimes),
  #   - the locally built `cache` executable: `*/.lake/build/bin`,
  #     `mathlib/.lake/build/ir/Cache`, `mathlib/.lake/build/lib/lean/Cache*`,
  #     `*.setup.json`, `*.rsp`,
  #   - the `log` and `inputs` fields of traces for modules that build compiles
  #     locally (`Batteries.Tactic.OpenPrivate` embeds an absolute `LEAN_PATH`
  #     and source paths); their `depHash` and `outputs` are identical.
  #
  # So the rule is: delete the first two, KEEP every trace, and empty the
  # `log` and `inputs` of all of them (neither takes part in the up-to-date
  # check, which compares `depHash` alone). Deleting traces (this function's previous behaviour)
  # was over-broad and fatal downstream: a missing trace is "stale" to Lake,
  # which then re-elaborates Mathlib. A trace's `depHash` is a pure function of
  # source, options, platform and the imports' artifact content hashes, so a
  # trace stays valid wherever the same bytes sit. `proofwidgets/widget` traces
  # must be kept too — without them Lake tries to run npm.
  #
  # Still a RULE, not an enumeration (the earlier list missed `bin/cache`
  # (~104 MB), `bin/cache.hash` and a stray `batteries` trace). `jq -S`
  # sorts keys so the rewrite is canonical; a trace `jq` cannot parse FAILS
  # the build rather than being left in place, since an unparsed trace is
  # exactly an unexamined source of nondeterminism.
  #
  # `$out` must reach the shell unquoted-by-Nix and quoted-by-shell.
  # `lib.escapeShellArg` single-quotes it, which yields `rm -rf -- '$out/…'` —
  # a no-op that exits 0, silently disabling the only thing making the hash
  # stable. Needs `jq` and `findutils` in the build's PATH.
  pruneNondeterministic = packagesDir: ''
    find ${packagesDir} -maxdepth 2 -name .git -type d -exec rm -rf {} +
    find ${packagesDir} \( -name '*.setup.json' -o -name '*.rsp' \) -delete
    rm -rf ${packagesDir}/*/.lake/build/bin
    rm -rf ${packagesDir}/mathlib/.lake/build/ir/Cache
    rm -rf ${packagesDir}/mathlib/.lake/build/lib/lean/Cache ${packagesDir}/mathlib/.lake/build/lib/lean/Cache.*
    find ${packagesDir} -name '*.trace' -print0 | xargs -0 -n 256 sh -c '
      set -e
      for f in "$@"; do
        jq -cS "(if has(\"log\") then .log = [] else . end) | (if has(\"inputs\") then .inputs = [] else . end)" "$f" > "$f.canon"
        mv "$f.canon" "$f"
      done
    ' sh
  '';

  # Make the pruned tree usable READ-ONLY by Lake (ADR-052).
  #
  # Lake caches artifact content hashes in `<artifact>.hash`, each exactly 16
  # lowercase hex digits. Mathlib's archives ship a few that are malformed
  # (`Mathlib/Tactic/FastInstance.olean.hash` has its leading zeros stripped,
  # and five more turn up in a full pass) or absent
  # (`proofwidgets/widget/package-lock.json.hash`); Lake then recomputes and
  # REWRITES them, which fails with `permission denied` on a store path. Which
  # files those are is a fact about the archives, not something to enumerate,
  # so let Lake canonicalise its own cache: replay the whole dependency graph
  # once, writable, before the tree is frozen.
  #
  # The pass must find everything up to date. A `Built` line means a trace
  # did not validate (the same defect as deleting traces) and that is refused
  # here rather than discovered as a multi-hour Mathlib rebuild downstream.
  #
  # `workspace` is a checkout with `lakefile.*` and `lake-manifest.json`;
  # `packagesDir` is the shell expression for the pruned tree. Needs `lake`
  # and `jq` on PATH.
  seedLakeHashes = {
    workspace,
    packagesDir,
    target ? "@mathlib/Mathlib",
  }: ''
    seed="$(mktemp -d)"
    mkdir -p "$seed/.lake"
    cp ${workspace}/lakefile.* ${workspace}/lean-toolchain ${workspace}/lake-manifest.json "$seed/"
    jq --arg d "${packagesDir}" \
      '.packages |= map({name, inherited: (.inherited // false), type: "path", dir: ($d + "/" + .name)})' \
      ${workspace}/lake-manifest.json > "$seed/.lake/package-overrides.json"
    (cd "$seed" && lake build --no-ansi ${target} 2>&1 | tee "$seed/seed.log")
    if grep -q ' Built ' "$seed/seed.log"; then
      echo "jackpkgs.lean: Lake rebuilt dependency modules while seeding; the pruned tree is not accepted by Lake." >&2
      grep ' Built ' "$seed/seed.log" | head -5 >&2
      exit 1
    fi
  '';

  # A Lake package-overrides document: the project's own `lake-manifest.json`
  # with every dependency repointed at a directory in the Nix store (ADR-052).
  #
  # Handed to Lake as `--packages=<file>`, it makes Lake resolve each package to
  # prebuilt, read-only store contents instead of `.lake/packages`, so nothing
  # is copied, cloned or written. Absolute `dir`s are accepted (measured).
  #
  # `dirOf` is total over the manifest's packages by construction (it is mapped
  # over them), so a dependency cannot be left pointing at the network.
  packageOverrides = {
    manifest,
    dirOf,
  }:
    manifest
    // {
      packages =
        map (p: {
          inherit (p) name;
          inherited = p.inherited or false;
          type = "path";
          dir = dirOf p.name;
        })
        (manifest.packages or []);
    };

  # lean4-nix's binary toolchain is unusable on aarch64-darwin without this.
  #
  # Upstream Lean's arm64 release binaries are already signed and already
  # resolve through `@rpath`. nixpkgs' darwin `fixupPhase` rewrites them anyway
  # — `fixDarwinDylibNames` runs `install_name_tool`, and `strip` follows — and
  # each rewrite both invalidates the signature and pushes the Mach-O load
  # commands past the header pad. The build fails outright on
  # `libleanshared_1.dylib`; dropping only `fixDarwinDylibNames` is worse, since
  # the build then succeeds and dyld rejects `libInit_shared.dylib` at run time
  # with "load commands do not fit in __TEXT segment filesize", which reads as
  # an unrelated fault.
  #
  # Verified by control: the same tarball unpacked and run untouched works.
  #
  # `stdenv` is a `callPackage` argument of lean4-nix's `lib/toolchain.nix`, so
  # overriding it here reaches every derivation that file makes.
  dontFixupStdenv = stdenv:
    stdenv
    // {
      mkDerivation = args: stdenv.mkDerivation (args // {dontFixup = true;});
    };
}
