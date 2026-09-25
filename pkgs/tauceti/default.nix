{
  lib,
  python312Packages,
  makeWrapper,
  git,
  gh,
  jq,
  tauceti-review,
  tauceti-progress,
  # From nvfetcher
  src,
  date,
}:
# The Tau Ceti worker CLI: one round picks a unit of work, does it, and stops.
#
# Upstream acquires its two engines at run time via `uvx --from git+https://github.com/...`.
# This build resolves them at build time instead, so a round needs no `uv`, reaches no network
# for its own tooling, and runs exactly the engine revisions this closure pins. See
# ./devendor-uvx.py for the rewrites and, more importantly, for the assertions that make an
# upstream refactor fail the build rather than silently restore the fetch.
#
# What is deliberately NOT pinned: `claude`, `codex`, `kiro-cli` and `lake`. The agent CLIs
# carry the operator's credentials and subscription, and `lake` belongs to whichever Lean
# toolchain the checkout nominates through elan. All four are left to the caller's PATH.
python312Packages.buildPythonApplication {
  pname = "tauceti";
  version = "0-unstable-${date}";
  inherit src;

  pyproject = true;
  build-system = [python312Packages.hatchling];

  dependencies = with python312Packages; [
    rich
    textual
  ];

  # Upstream's tests drive `gh` and the agent CLIs against live services.
  doCheck = false;

  nativeBuildInputs = [makeWrapper];

  postPatch = ''
    python3 ${./devendor-uvx.py} . \
      ${lib.getExe tauceti-review} \
      ${lib.getExe tauceti-progress} \
      ${tauceti-progress.version}
  '';

  # `prompts/` and `scripts/` are force-included into the wheel by upstream's hatch config, so
  # the shell helpers (claim.sh, git-safe-push, gh-safe-pr-create) land in site-packages rather
  # than $out/bin and miss the default patchShebangs pass.
  postFixup = ''
    patchShebangs $out/${python312Packages.python.sitePackages}/tauceti_worker/scripts

    wrapProgram $out/bin/tauceti \
      --prefix PATH : ${lib.makeBinPath [git gh jq tauceti-review tauceti-progress]}
  '';

  meta = {
    description = "Autonomous worker for the Tau Ceti AI-authored Lean library";
    homepage = "https://github.com/TauCetiProject/TauCetiWorker";
    # Placeholder, not upstream's declaration: TauCetiWorker ships no LICENSE file and GitHub
    # reports none, unlike TauCetiReview and TauCetiProgress which are both Apache-2.0. Almost
    # certainly an oversight worth raising upstream. Recorded here rather than as `unfree` so the
    # package stays buildable without `allowUnfree`; correct it once upstream declares one.
    license = lib.licenses.mit;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "tauceti";
  };
}
