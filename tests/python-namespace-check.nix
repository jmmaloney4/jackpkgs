{lib}: let
  nsCheck = import ../lib/python-namespace-check.nix {inherit lib;};
  inherit (nsCheck) checkMembers;

  fixturesRoot = ../tests/fixtures/python-workspace;

  mixedRoot = fixturesRoot + "/mixed-namespace";
  mixedSrcA = mixedRoot + "/tools/converge-bridge/src";
  mixedSrcB = mixedRoot + "/tools/aparecium/src";

  cleanRoot = fixturesRoot + "/clean-namespace";
  cleanSrcA = cleanRoot + "/tools/converge-bridge/src";
  cleanSrcB = cleanRoot + "/tools/aparecium/src";
in {
  testMixedNamespaceIsDetected = {
    expr = checkMembers [
      {
        name = "converge-bridge";
        srcDir = mixedSrcA;
      }
      {
        name = "aparecium";
        srcDir = mixedSrcB;
      }
    ];
    expected = [
      {
        rootName = "jmmaloney4";
        withInit = ["converge-bridge"];
        withoutInit = ["aparecium"];
      }
    ];
  };

  testConsistentPep420NoConflicts = {
    expr = checkMembers [
      {
        name = "converge-bridge";
        srcDir = cleanSrcA;
      }
      {
        name = "aparecium";
        srcDir = cleanSrcB;
      }
    ];
    expected = [];
  };

  testEmptyMemberListReturnsEmpty = {
    expr = checkMembers [];
    expected = [];
  };

  testSingleMemberNoConflicts = {
    expr = checkMembers [
      {
        name = "solo";
        srcDir = mixedSrcA;
      }
    ];
    expected = [];
  };
}
