# Fixture: a manifest whose declared `tag` disagrees with any tag it might
# be resolved for (loadManifest is always called with a tag other than
# "v9.9.9" in tests/lean.nix), so loadManifest must throw.
{
  tag = "v9.9.9";
  toolchain = "lean4-binary-placeholder";
}
