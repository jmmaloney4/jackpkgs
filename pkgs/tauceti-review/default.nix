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
# The Tau Ceti AI review engine. Like the progress reporter it declares no Python dependencies
# and shells out to `git`, `gh`, and whichever agent CLI is configured.
#
# The wheel is NOT sufficient on its own. `pyproject.toml` ships only `packages = ["runner"]`,
# but `runner/cli.py:resolve_repo_dir` insists on a directory holding BOTH `rubrics/` and
# `runner/review.py` -- "engine and rubrics together, so they never drift" -- and when it cannot
# find one it clones TauCetiReview from GitHub into `~/.cache/tauceti-review` on every single
# run. So we also install the full source tree and point `$TAUCETI_REVIEW_DIR` at it, which is
# the second candidate in that resolution order. That is what makes this package hermetic
# rather than merely installed.
#
# Known, deliberate imprecision: `runner/cli.py:rubrics_repo_sha` reports which rubric revision
# ran by `git rev-parse`-ing that directory. A store path has no `.git`, so it takes upstream's
# documented fallback -- the remote `main` tip, flagged via `--rubrics-sha-approx`. The posted
# provenance is therefore an *approximation marked as one*, never a silent claim. Passing
# `--rubrics-sha` would not fix it: that flag routes through `engine_at()`, which git-fetches
# the named sha and replaces the engine, defeating the point of packaging it.
python312Packages.buildPythonApplication {
  pname = "tauceti-review";
  inherit src version;

  pyproject = true;
  build-system = [python312Packages.setuptools];

  # Upstream's tests drive `gh` and the agent CLIs against live services.
  doCheck = false;

  nativeBuildInputs = [makeWrapper];

  # `runner/*.py` use flat sibling imports (`import archive`, `from ledger import Ledger`) and
  # are executed as scripts out of this tree, so copy it wholesale rather than cherry-picking.
  postInstall = ''
    mkdir -p $out/share/tauceti-review
    cp -r rubrics runner $out/share/tauceti-review/
  '';

  # `--set-default`, not `--set`: an operator pinning a local checkout for engine development
  # still wins. PATH is prefixed only with the two CLIs every run needs; `claude`/`codex`/
  # `kiro-cli` are deliberately left to the caller's PATH, since they carry user credentials
  # and subscriptions that have no business being pinned by a package.
  postFixup = ''
    for bin in tauceti-review tauceti-review-costs; do
      wrapProgram $out/bin/$bin \
        --set-default TAUCETI_REVIEW_DIR $out/share/tauceti-review \
        --prefix PATH : ${lib.makeBinPath [git gh]}
    done
  '';

  meta = {
    description = "Run the Tau Ceti AI code review on a PR using your own agent subscription";
    homepage = "https://github.com/TauCetiProject/TauCetiReview";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    mainProgram = "tauceti-review";
  };
}
