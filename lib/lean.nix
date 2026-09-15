# Pure helpers behind `jackpkgs.lean` (see docs/internal/designs/049-lean-toolchain-module.md).
#
# A Lean project's environment is derived entirely from two files the checkout
# already commits — `lean-toolchain` and `lake-manifest.json` — so there is no
# second place to restate a pin and nothing that can drift from the project.
{lib}: rec {
  # Strip surrounding whitespace, including the trailing newline every
  # `lean-toolchain` carries. `lib.trim` is too new to rely on across the
  # nixpkgs revisions consumers pin.
  trim = let
    isSpace = c: c == " " || c == "\t" || c == "\n" || c == "\r";
    dropWhile = s: let
      chars = lib.stringToCharacters s;
      keep = lib.lists.findFirstIndex (c: !(isSpace c)) null chars;
    in
      if keep == null
      then ""
      else lib.concatStrings (lib.drop keep chars);
    reverse = s: lib.concatStrings (lib.reverseList (lib.stringToCharacters s));
  in
    s: reverse (dropWhile (reverse (dropWhile s)));

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
  in
    if lib.hasPrefix prefix pinned
    then lib.removePrefix prefix pinned
    else
      throw ''
        jackpkgs.lean: unsupported lean-toolchain pin ${builtins.toJSON pinned}.
        Only `leanprover/lean4:<tag>` pins resolve to a binary toolchain.
      '';

  readToolchainTag = src: parseToolchain (builtins.readFile "${src}/lean-toolchain");

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

            just lean-toolchain-fetch ${tag}

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
  loadManifest = {
    path,
    upstreamDir,
  }: let
    loaded = import path;
  in
    if lib.isFunction loaded
    then loaded {upstream = toString upstreamDir;}
    else loaded;

  # Every path under a Lean project's dependency tree that `lake exe cache get`
  # does NOT reproduce byte-for-byte between runs.
  #
  # Measured 2026-09-15 at Mathlib 0df444a3: of ~125,000 files, exactly 58
  # differed across two independent fetches, and all 58 belong to the `cache`
  # CLI that Mathlib ships and that `lake exe cache get` must compile before it
  # can run. Its build artifacts embed absolute paths, so they cannot appear in
  # a fixed-output derivation. Mathlib's own artifacts — 8,322 `.olean` and
  # 8,322 `.ilean` — were identical, and the fetched set did not vary with the
  # importing file.
  cacheToolArtifacts = [
    "bin/cache.rsp"
    "bin/cache.trace"
    "ir/Cache"
    "lib/lean/Cache"
  ];

  # Shell fragment that removes the above from a package's `.lake/build`.
  pruneCacheToolArtifacts = buildDir:
    lib.concatMapStringsSep "\n"
    (p: "rm -rf -- ${lib.escapeShellArg "${buildDir}/${p}"}")
    cacheToolArtifacts;

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
