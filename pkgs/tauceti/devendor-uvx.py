#!/usr/bin/env python3
"""Replace TauCetiWorker's runtime `uvx` fetches with the Nix-built engine binaries.

The worker normally acquires its two engines at run time, by shelling out to
`uvx --from git+https://github.com/...`. That is three problems in a Nix package: it needs
`uv` on PATH, it reaches the network mid-round, and the revision it lands on is whatever the
remote happens to be rather than anything this closure pins. Every such call site is rewritten
here to invoke a store path instead.

Each rewrite asserts how many occurrences it expects and exits non-zero on any other count, so
an upstream refactor that moves or renames a call site FAILS THE BUILD. It cannot quietly stop
applying and leave the worker fetching from the network again -- which is the one failure mode
that would be invisible from the outside, since the worker would still work.

Usage: devendor-uvx.py SRCROOT REVIEW_BIN PROGRESS_BIN PROGRESS_REV
"""

import pathlib
import re
import sys

root, review_bin, progress_bin, progress_rev = (
    pathlib.Path(sys.argv[1]),
    sys.argv[2],
    sys.argv[3],
    sys.argv[4],
)


def edit(relpath, pattern, repl, expect, what):
    path = root / relpath
    text = path.read_text()
    new, n = re.subn(pattern, lambda _m: repl, text)
    if n != expect:
        sys.exit(
            f"devendor-uvx: {relpath}: expected {expect} occurrence(s) of {what}, found {n}.\n"
            f"  Upstream moved or rewrote the call site. Re-derive this patch against the new\n"
            f"  source before bumping the package -- do NOT relax the count, or the worker will\n"
            f"  silently go back to fetching its engines from the network."
        )
    path.write_text(new)


def edit_literal(relpath, old, new, what):
    """Exact-text variant of `edit`, for prose too long to write as a readable regex."""
    path = root / relpath
    text = path.read_text()
    n = text.count(old)
    if n != 1:
        sys.exit(
            f"devendor-uvx: {relpath}: expected 1 occurrence of {what}, found {n}.\n"
            f"  Upstream rewrote it. Re-derive this patch against the new source."
        )
    path.write_text(text.replace(old, new))


# The worker nominates an exact TauCetiProgress revision. Packaging a different one would run an
# engine no other worker is running, so the two pins are welded together here rather than left to
# agree by luck: bumping `tauceti` without bumping `tauceti-progress` stops the build.
constants = (root / "tauceti_worker" / "constants.py").read_text()
m = re.search(
    r'PROGRESS_REF = os\.environ\.get\("TAUCETI_PROGRESS_REF", "([0-9a-f]{40})"\)',
    constants,
)
if not m:
    sys.exit(
        "devendor-uvx: constants.py: could not find PROGRESS_REF; re-derive this patch."
    )
if m.group(1) != progress_rev:
    sys.exit(
        f"devendor-uvx: engine pin mismatch.\n"
        f"  TauCetiWorker constants.py PROGRESS_REF = {m.group(1)}\n"
        f"  packaged tauceti-progress        rev     = {progress_rev}\n"
        f"  Update the [tauceti-progress] src.manual pin in nvfetcher.toml to match, re-run\n"
        f"  nvfetcher, and rebuild."
    )

# The review engine, on the non-bubble review path and on the outbox-sync path. Upstream honours
# $TAUCETI_REVIEW_ENGINE_DIR on the sync path but NOT on the review path, so an env var alone
# cannot cover both -- hence a rewrite.
edit(
    "tauceti_worker/work_units.py",
    r'"uvx",\s*"--from",\s*f"git\+https://github\.com/\{REVIEW\}",\s*"tauceti-review",',
    f'"{review_bin}",',
    2,
    "the uvx tauceti-review invocation",
)

# The progress reporter. This one has no env-var escape hatch upstream at all, and it runs on
# every round, so without this rewrite `uv` would remain a hard runtime requirement.
edit(
    "tauceti_worker/survey.py",
    r'"uvx",\s*"--cache-dir",\s*str\(cache\),\s*"--from",\s*'
    r'f"git\+https://github\.com/\{PROGRESS\}@\{PROGRESS_REF\}",\s*"tauceti-progress",',
    f'"{progress_bin}",',
    1,
    "the uvx tauceti-progress invocation",
)

# `doctor` and `preflight` both treat a missing `uvx` as a hard failure. With the engines
# vendored that is no longer true, and leaving it would tell the operator to install a tool the
# package exists to avoid.
edit(
    "tauceti_worker/cli.py",
    r'rows\.append\(\("uv/uvx", _have\("uvx"\), "required \(runs tauceti and fetches the review engine\)"\)\)',
    'rows.append(("engines", True, "vendored by Nix; no uvx fetch"))',
    1,
    "the doctor uv/uvx row",
)
edit(
    "tauceti_worker/cli.py",
    r'if not ok and name in \("gh", "git", "uv/uvx", "gh auth"\):',
    'if not ok and name in ("gh", "git", "gh auth"):',
    1,
    "the doctor hard-failure set",
)
edit(
    "tauceti_worker/cli.py",
    r'for t in \("gh", "git", "uvx"\):',
    'for t in ("gh", "git"):',
    1,
    "the preflight PATH check",
)

# The rewrite above strips the fetch that `progress_argv`'s docstring and its per-revision cache
# key both exist to manage. Leaving them would leave the source describing a mechanism the built
# package does not have -- worse than no comment at all.
edit_literal(
    "tauceti_worker/survey.py",
    '''    """The TauCetiProgress CLI, cached separately for each immutable source revision.

    uv's shared ``uvx`` tool environment is keyed by the unchanged package name/version rather than
    reliably by the Git revision passed through ``--from``. Reusing it after a pin bump can therefore
    execute an older checkout. A per-ref cache preserves normal reuse within a release while making
    the revision part of the cache identity.
    """
    cache = state / "cache" / "uvx" / "tauceti-progress" / PROGRESS_REF
''',
    '''    """The TauCetiProgress CLI, resolved at build time to the revision constants.py names.

    Upstream fetches this through ``uvx`` and keeps a per-revision cache, because uv keys its
    shared tool environment by package name/version rather than by the revision passed to
    ``--from`` and would otherwise re-run a stale checkout after a pin bump. This build resolves
    the revision when the package is built, so there is no fetch to go stale and no cache to key.
    ``state`` is retained to keep the call signature.
    """
''',
    "the progress_argv docstring and its uvx cache key",
)

print("devendor-uvx: all call sites rewritten", file=sys.stderr)
