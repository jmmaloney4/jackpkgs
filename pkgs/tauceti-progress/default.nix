{
  lib,
  python313Packages,
  makeWrapper,
  git,
  gh,
  tauceti-tools,
  # From nvfetcher
  src,
  version,
}:
# The roadmap progress reporter. It shells out to `git` and `gh` and imports shared project
# configuration from `tauceti-tools`. Its prompts install *inside* the package (`progress/prompts/*.md`, resolved as
# `Path(__file__).parent / "prompts"`), so nothing outside the wheel is needed at runtime.
python313Packages.buildPythonApplication {
  pname = "tauceti-progress";
  inherit src version;

  pyproject = true;
  build-system = [python313Packages.setuptools];

  dependencies = [tauceti-tools];

  # Upstream's tests drive `gh` against live GitHub.
  doCheck = false;

  nativeBuildInputs = [makeWrapper];

  postFixup = ''
    wrapProgram $out/bin/tauceti-progress \
      --prefix PATH : ${lib.makeBinPath [git gh]}
  '';

  meta = {
    description = "Per-roadmap progress reports for the Tau Ceti Lean library";
    homepage = "https://github.com/TauCetiProject/TauCetiProgress";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "tauceti-progress";
  };
}
