# fixture-secondary

Minimal dependency-free secondary uv workspace used by
`tests/python-extra-workspaces.nix` to exercise
`jackpkgs.python.extraWorkspaces`. The lockfile is generated with
`uv lock` in this directory and should stay dependency-free so it never
goes stale.
