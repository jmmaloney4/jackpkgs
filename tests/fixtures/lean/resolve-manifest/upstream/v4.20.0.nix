# Fixture: an upstream-only manifest (no vendored counterpart), so
# resolveManifestPath must fall back to this file.
{
  tag = "v4.20.0";
  toolchain = "upstream-only-placeholder";
}
