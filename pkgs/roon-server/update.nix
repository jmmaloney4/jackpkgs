{
  lib, pkgs
}: ''
prefetchOutput="$(${lib.getExe' pkgs.nix "nix-prefetch-url"} --print-path https://download.roonlabs.com/updates/production/RoonServer_linuxx64.tar.bz2)"

# https://unix.stackexchange.com/a/628576/295928
set -o noglob
IFS=$'\n' data=($prefetchOutput)
set +o noglob

newHash="\${data[0]}"
tarPath="\${data[1]}"
newVersion="$(${lib.getExe pkgs.gnutar} -zxvOf $tarPath RoonServer/VERSION 2> /dev/null | head -n 1)"

echo $newVersion $newHash $tarPath

${lib.getExe pkgs.gnused} --in-place "s/hash = \"sha256\:[a-z0-9]*\"/hash = \"sha256:$newHash\"/g" "$0"
${lib.getExe pkgs.gnused} --in-place "s/version = \"[0-9]*\"/version = \"$newVersion\"/g" "$0"
''