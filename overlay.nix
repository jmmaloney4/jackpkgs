# You can use this file as a nixpkgs overlay. This is useful in the
# case where you don't want to add the whole NUR namespace to your
# configuration.
#
# When used from the flake, bun2nix inputs are passed as the first argument.
inputs: self: super:
if !(super ? callPackage && super ? system)
then {}
else let
  # When used standalone (without flake inputs), fetch bun2nix from GitHub.
  bun2nixOverlay =
    if inputs ? bun2nix
    then inputs.bun2nix.overlays.default
    else
      (import (builtins.fetchTarball {
        url = "https://github.com/nix-community/bun2nix/archive/f2bc12af1a6369648aac41041ceeaa0b866599c6.tar.gz";
        sha256 = "sha256-oQvcadh2BCkrog+SGrG6YffKJrveYpjj3TdQJWaKhaM=";
      })).overlays.default;
  isReserved = n: n == "lib" || n == "overlays" || n == "modules";
  nameValuePair = n: v: {
    name = n;
    value = v;
  };
  nvfetcherSources = super.callPackage ./_sources/generated.nix {};
  # `super.extend`, not `super // (bun2nixOverlay self super)`: the plain `//`
  # merged bun2nix's attributes onto `super` but left `callPackage` bound to
  # `super`'s own scope, so `pkgs/gemini-proxy`'s `bun2nix` argument was
  # unresolvable and any access to `gemini-proxy` through this overlay aborted
  # with "Function called without required argument". That was invisible while
  # #384 made the whole overlay recurse first. `extend` rebuilds the fixpoint so
  # `callPackage` resolves against a scope that actually contains bun2nix --
  # the same thing `flake.nix` does with `pkgs.extend`. It also stops threading
  # this overlay's `self` into another overlay's construction.
  superWithBun2nix = super.extend bun2nixOverlay;
  # Define packages inline instead of importing default.nix
  allPackages = {
    csharpier = super.callPackage ./pkgs/csharpier {};
    biome = super.callPackage ./pkgs/biome {};
    codex-proxy = super.callPackage ./pkgs/codex-proxy {
      inherit (nvfetcherSources.codex-proxy) src version;
    };
    codex-proxy-rs = super.callPackage ./pkgs/codex-proxy-rs {
      inherit (nvfetcherSources.codex-proxy-rs) src version;
    };
    dbn-cli = super.callPackage ./pkgs/dbn-cli {
      inherit (nvfetcherSources.dbn-cli) src version;
    };
    docfx = super.callPackage ./pkgs/docfx {};
    gemini-proxy = superWithBun2nix.callPackage ./pkgs/gemini-proxy {
      inherit (nvfetcherSources.gemini-proxy) src version;
    };
    gawkbot = super.callPackage ./pkgs/gawkbot {
      inherit (nvfetcherSources."gawkbot-${super.system}") src version;
    };
    epub2tts = super.callPackage ./pkgs/epub2tts {};
    imessage-bridge = super.callPackage ./pkgs/imessage-bridge {};
    mcp-ynab = super.callPackage ./pkgs/mcp-ynab {
      inherit (nvfetcherSources.mcp-ynab) src version;
    };
    seedtool-cli = super.callPackage ./pkgs/seedtool-cli {};
    spooktacular = super.callPackage ./pkgs/spooktacular {
      inherit (nvfetcherSources.spooktacular) src date;
    };
    tauceti = super.callPackage ./pkgs/tauceti {
      inherit (nvfetcherSources.tauceti) src date;
      inherit (allPackages) tauceti-review tauceti-progress;
    };
    tauceti-progress = super.callPackage ./pkgs/tauceti-progress {
      inherit (nvfetcherSources.tauceti-progress) src version;
    };
    tauceti-review = super.callPackage ./pkgs/tauceti-review {
      inherit (nvfetcherSources.tauceti-review) src version;
    };
    tod = super.callPackage ./pkgs/tod {
      inherit (nvfetcherSources.tod) src version;
      nvCargoLock = nvfetcherSources.tod.cargoLock;
    };
  };
  jackLib = import ./lib {pkgs = super;};
  nurAttrs =
    {
      lib = jackLib;
      modules = import ./modules;
      homeManagerModules = import ./modules/home-manager;
      darwinModules = import ./modules/nix-darwin;
      overlays = import ./overlays;
    }
    # NOTE: deliberately NOT platform-filtered. Deciding which attribute
    # *names* this overlay exports by inspecting each package's
    # `meta.platforms` forces derivations built by `callPackage` against the
    # *final* package set -- the very fixpoint this overlay participates in --
    # so the overlay's attribute names would depend on evaluating packages
    # that depend on the completed overlay. That is an infinite recursion
    # (#384), and no amount of extra laziness fixes it: a name-level filter
    # driven by values is inherently recursive here.
    #
    # This matches nixpkgs' own posture -- overlays do not platform-filter.
    # `meta.platforms` is still enforced at build time by `checkMeta`, which
    # yields a better error ("not available on ...") than an attribute
    # silently vanishing. `flake.nix` keeps its `platformFilteredPackages`
    # because `packages.<system>` genuinely must not contain unbuildable
    # attrs (for `nix flake show` / CI); it computes the filter against an
    # already-complete `pkgs`, outside any overlay, so it is not recursive.
    // allPackages;
in
  builtins.listToAttrs
  (map (n: nameValuePair n nurAttrs.${n})
    (builtins.filter (n: !isReserved n)
      (builtins.attrNames nurAttrs)))
