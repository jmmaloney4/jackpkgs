# Fixture: a vendored manifest for v4.34.0, deliberately also present
# upstream (see ../upstream/v4.34.0.nix) so tests/lean.nix can assert
# resolveManifestPath prefers this file.
{
  tag = "v4.34.0";
  toolchain = "vendored-placeholder";
}
