{pkgs}:
with pkgs.lib; rec {
  # Add your library functions here

  # Justfile generation helpers
  # These helpers make it easy to generate justfile content without indentation issues
  justfile = import ./justfile-helpers.nix {lib = pkgs.lib;};

  /**
  Filter an attribute set so that it is returned only when the
  evaluation `system` is included in `systems`.

  Example:

  ```nix
  myLib.onlyOnSystems ["x86_64-linux" "aarch64-linux"] pkgs.system {
    foo = ...;
  }
  ```
  will yield the `foo` attribute only on the listed systems.
  */
  onlyOnSystems = systems: system: attrs:
    optionalAttrs (elem system systems) attrs;

  /**
  Filter an attribute set of packages using each package's
  `meta.platforms` field. Packages without a `meta.platforms`
  specification are kept.

  Example:

  ```nix
  myLib.filterByPlatforms pkgs.system {
    foo = pkgs.callPackage ./foo {};
    bar = pkgs.callPackage ./bar {};
  }
  ```
  will omit any package whose `meta.platforms` list does not
  include the current system.
  */
  filterByPlatforms = system: attrs:
    filterAttrs (_: pkg: let
      pls = attrByPath ["meta" "platforms"] platforms.all pkg;
    in
      elem system pls)
    attrs;
}
