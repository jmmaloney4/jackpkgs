# Behavioural test for modules/nixos/cache-target-pruner.sh: runs the real
# script against a temp cache dir. nix-unit (tests/nixos-modules.nix) is
# eval-only and cannot see what the script deletes.
#
# Pins the two deletion-path refusals:
#   * a tagged cache with an unreadable subtree is SKIPPED, not pruned on the
#     strength of its readable (old) files -- recency is indeterminate;
#   * a cache dir on a different filesystem than the measured one is refused.
# Plus a control (a fully readable, old, tagged cache IS pruned), so the
# negative assertions are meaningful: the script can demonstrably delete here.
{pkgs}: let
  prune = pkgs.writeShellApplication {
    name = "cache-target-pruner";
    runtimeInputs = [pkgs.coreutils pkgs.findutils pkgs.gnugrep];
    text = builtins.readFile ../modules/nixos/cache-target-pruner.sh;
  };
  # A path guaranteed to be on a different device than the build dir.
  otherFs =
    if pkgs.stdenv.hostPlatform.isDarwin
    then "/dev"
    else "/proc";
in
  pkgs.runCommand "cache-target-pruner-script" {nativeBuildInputs = [pkgs.coreutils];} ''
    if [ "$(id -u)" -eq 0 ]; then
      echo "FAIL: running as root, chmod 000 would not make the subtree unreadable; test cannot show the case" >&2
      exit 1
    fi
    sig='Signature: 8a477f597d28d172789f06886806bc55'
    root=$PWD/home/.cache
    mkdir -p "$root/locked/sub" "$root/old"
    for c in locked old; do printf '%s\n' "$sig" > "$root/$c/CACHEDIR.TAG"; done
    echo x > "$root/locked/readable-old"
    echo x > "$root/locked/sub/hidden-recent"
    echo x > "$root/old/file"
    touch -d '2 hours ago' "$root/locked/readable-old" "$root/old/file" \
      "$root/locked/CACHEDIR.TAG" "$root/old/CACHEDIR.TAG"
    chmod 000 "$root/locked/sub"
    trap 'chmod -R u+rwx "$PWD/home" 2>/dev/null || true' EXIT

    # Floor 101 forces "below floor"; target 101 so it never stops early.
    log=$(${prune}/bin/cache-target-pruner "$root" "$PWD" 101 101 15 4)
    echo "$log"

    [ -d "$root/locked" ] || { echo "FAIL: cache with unreadable subtree was pruned" >&2; exit 1; }
    echo "$log" | grep -q "SKIP $root/locked (could not determine recency)" \
      || { echo "FAIL: no indeterminate-recency skip logged" >&2; exit 1; }
    [ ! -e "$root/old" ] || { echo "FAIL: control (readable old cache) was not pruned" >&2; exit 1; }

    # Wrong filesystem: nothing may be touched.
    mkdir -p "$root/again"
    printf '%s\n' "$sig" > "$root/again/CACHEDIR.TAG"
    touch -d '2 hours ago' "$root/again/CACHEDIR.TAG"
    log=$(${prune}/bin/cache-target-pruner "$root" ${otherFs} 101 101 15 4)
    echo "$log"
    echo "$log" | grep -q "is not on ${otherFs}" || { echo "FAIL: no wrong-filesystem skip logged" >&2; exit 1; }
    [ -d "$root/again" ] || { echo "FAIL: pruned a cache dir on a different filesystem" >&2; exit 1; }

    touch $out
  ''
