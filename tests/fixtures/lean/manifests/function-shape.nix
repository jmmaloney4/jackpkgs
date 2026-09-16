# Fixture: a manifest in the "function" shape jackpkgs' own vendored
# manifests use, so they can inherit from upstream's sibling files by
# relative path via the supplied `upstream` directory. This fixture ignores
# `upstream` and returns the same attrset as ./plain-attrset.nix, so
# tests/lean.nix can assert loadManifest yields equal results for both
# shapes.
{upstream}: {
  tag = "v4.34.0";
  toolchain = "lean4-binary-placeholder";
}
