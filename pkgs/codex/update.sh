#!/usr/bin/env bash
set -euo pipefail

SCRIPTDIR=$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cd "$TMP"
git clone --depth 1 https://github.com/openai/codex
cd codex
rev=$(git rev-parse HEAD)
sha=$(nix-prefetch-url --unpack https://github.com/openai/codex/archive/$rev.tar.gz)

node2nix -i codex-cli/package.json -c "$SCRIPTDIR/default.nix" -o "$SCRIPTDIR/node-packages.nix" -e "$SCRIPTDIR/node-env.nix"

sed -i "s|src = .*|src = fetchgit {\n      url = \"https://github.com/openai/codex\";\n      rev = \"$rev\";\n      sha256 = \"$sha\";\n      fetchSubmodules = false;\n    } + \"/codex-cli\";|" "$SCRIPTDIR/node-packages.nix"

echo "commit-msg=\"[codex] update to $rev\""
