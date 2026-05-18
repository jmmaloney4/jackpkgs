{lib}: let
  mkOverlay = args: import ../lib/python-package-fixes.nix ({inherit lib;} // args);

  mkPackage = old: {
    overrideAttrs = f: f old;
  };

  final = {
    setuptools = "setuptools-pkg";
    meson-python = "meson-python-pkg";
    meson = "meson-pkg";
    ninja = "ninja-pkg";
  };

  prev = {
    beancount = mkPackage {
      nativeBuildInputs = ["existing-native"];
    };

    peewee = mkPackage {
      nativeBuildInputs = [];
    };
  };
in {
  testBuildFixesAppendPythonAndNativeBuildInputs = let
    overlay = mkOverlay {
      packageFixes.beancount = {
        pythonNativeBuildInputs = ["meson-python" "meson" "ninja"];
        nativeBuildInputs = ["bison-pkg" "flex-pkg"];
      };
    };
    fixed = overlay final prev;
  in {
    expr = fixed.beancount.nativeBuildInputs;
    expected = [
      "existing-native"
      "meson-python-pkg"
      "meson-pkg"
      "ninja-pkg"
      "bison-pkg"
      "flex-pkg"
    ];
  };

  testLegacySetuptoolsPackagesBecomeBuildFixes = let
    overlay = mkOverlay {
      packageFixes = {};
      setuptoolsPackages = ["peewee"];
    };
    fixed = overlay final prev;
  in {
    expr = fixed.peewee.nativeBuildInputs;
    expected = ["setuptools-pkg"];
  };

  testMissingTargetPackageIsIgnored = let
    overlay = mkOverlay {
      packageFixes.absent = {
        pythonNativeBuildInputs = ["meson-python"];
      };
    };
    fixed = overlay final prev;
  in {
    expr = fixed ? absent;
    expected = false;
  };
}
