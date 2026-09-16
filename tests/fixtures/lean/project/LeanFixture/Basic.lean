import Batteries.Data.UnionFind.Basic

open Batteries

/-- Names a declaration that exists only in `batteries`, never in the Lean
    toolchain's own stdlib. Compiling this file therefore fails outright
    unless `LEAN_PATH` reaches the Nix-built dependency, which is the single
    thing the source-build branch of `jackpkgs.lean` is responsible for. -/
def emptyUnionFind : UnionFind := .empty
