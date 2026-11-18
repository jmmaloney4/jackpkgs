{
  lib,
  python3Packages,
  # From nvfetcher
  src,
  version,
}:
python3Packages.buildPythonApplication {
  pname = "pirateface";
  # nvfetcher tracks the git tag (v0.2.24); the Python version has no "v".
  version = lib.removePrefix "v" version;
  inherit src;
  pyproject = true;

  build-system = [python3Packages.hatchling];
  dependencies = with python3Packages; [
    huggingface-hub
    libtorrent-rasterbar
    tqdm
  ];

  # nixpkgs' libtorrent-rasterbar bindings install the `libtorrent` module
  # without dist-info, so the metadata-based runtime-deps check cannot see it.
  # The import check below still proves the module is present.
  pythonRemoveDeps = ["libtorrent"];
  pythonImportsCheck = ["pirateface" "libtorrent"];
  doCheck = false;

  meta = {
    description = "Download Hugging Face models over BitTorrent from Pirate Face seeders";
    homepage = "https://pirateface.co";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "pirateface";
  };
}
