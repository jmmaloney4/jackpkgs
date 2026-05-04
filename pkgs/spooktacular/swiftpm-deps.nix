# Auto-generated Swift PM dependency pinning for spooktacular.
# Regenerate: swift package resolve && scripts/update-swiftpm-deps.py
{ fetchgit }:

{
  swift-argument-parser = fetchgit {
    url = "https://github.com/apple/swift-argument-parser";
    rev = "626b5b7b2f45e1b0b1c6f4a309296d1d21d7311b";
    sha256 = "sha256-90ECc3iEmxvOUk9iLKbQdQEz88dOisPqWsJLOFcKUV8=";
  };
  swift-docc-plugin = fetchgit {
    url = "https://github.com/swiftlang/swift-docc-plugin";
    rev = "e977f65879f82b375a044c8837597f690c067da6";
    sha256 = "sha256-fQVlaoD774GJK8z4iDDRvt3H7S6NZrObOSLwW4poQok=";
  };
  swift-docc-symbolkit = fetchgit {
    url = "https://github.com/swiftlang/swift-docc-symbolkit";
    rev = "b45d1f2ed151d057b54504d653e0da5552844e34";
    sha256 = "sha256-+uQQiqVAon1UefkIM2FXwQIR5PVgR1K5e76Gvj4/g5M=";
  };
}
