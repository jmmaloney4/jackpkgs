{
  lib,
  python312Packages,
  makeWrapper,
  git,
  gh,
  # From nvfetcher
  src,
  version,
}:
# The roadmap progress reporter. It has no Python dependencies by design -- it shells out to
# `git` and `gh` and talks to Zulip over the standard library -- so the wheel is the whole
# package. Its prompts install *inside* the package (`progress/prompts/*.md`, resolved as
# `Path(__file__).parent / "prompts"`), so nothing outside the wheel is needed at runtime.
python312Packages.buildPythonApplication {
  pname = "tauceti-progress";
  inherit src version;

  pyproject = true;
  build-system = [python312Packages.setuptools];

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
