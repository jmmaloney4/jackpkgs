# https://stackoverflow.com/a/4774063
SCRIPTPATH="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

prefetchOutput="$(nix-prefetch-url --print-path https://download.roonlabs.com/updates/production/RoonServer_linuxx64.tar.bz2)"

# https://unix.stackexchange.com/a/628576/295928
set -o noglob
data=($prefetchOutput)
set +o noglob

newHash=${data[0]}
tarPath=${data[1]}
newVersion="$(tar -jxvOf $tarPath RoonServer/VERSION 2> /dev/null | head -n 1)"


sed --in-place "s/hash = \"sha256\:[a-z0-9]*\"/hash = \"sha256:$newHash\"/g" "$SCRIPTPATH/default.nix"
sed --in-place "s/version = \"[0-9]*\"/version = \"$newVersion\"/g" "$SCRIPTPATH/default.nix"
echo "commit-msg=\"[roon] update to $newVersion\"" >> "$GITHUB_OUTPUT"

