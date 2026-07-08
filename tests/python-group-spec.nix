{lib}: let
  gs = import ../lib/python-group-spec.nix {inherit lib;};
  envSel = import ../lib/python-env-selection.nix {inherit lib;};

  # Synthetic uv2nix-shaped deps for a 3-member workspace.
  #   root  defines groups: dev, test, research  (default-groups: none)
  #   libA  defines groups: dev, test            (default-groups: [dev])
  #   libB  defines no groups                     (default-groups: none)
  depsGroups = {
    root = ["dev" "test" "research"];
    libA = ["dev" "test"];
    libB = [];
  };
  depsDefault = {
    root = [];
    libA = ["dev"];
    libB = [];
  };
in {
  # ---------------------------------------------------------------
  # resolveSpec
  # ---------------------------------------------------------------
  testResolveTrueIsAllGroups = {
    expr = gs.resolveSpec {
      inherit depsDefault depsGroups;
      includeGroups = true;
    };
    expected = depsGroups;
  };

  testResolveFalseIsDefault = {
    expr = gs.resolveSpec {
      inherit depsDefault depsGroups;
      includeGroups = false;
    };
    expected = depsDefault;
  };

  # research: only root defines it, so only root gains it. libA keeps its
  # default [dev] and adds nothing (does not define research). libB stays empty.
  testResolveListUnionsWithDefaultsAndIntersects = {
    expr = gs.resolveSpec {
      inherit depsDefault depsGroups;
      includeGroups = ["research"];
    };
    expected = {
      root = ["research"];
      libA = ["dev"];
      libB = [];
    };
  };

  # test: root gains it; libA already has [dev] default and adds test.
  testResolveListAddsToMembersThatDefineIt = {
    expr = gs.resolveSpec {
      inherit depsDefault depsGroups;
      includeGroups = ["test"];
    };
    expected = {
      root = ["test"];
      libA = ["dev" "test"];
      libB = [];
    };
  };

  testResolveEmptyListEqualsDefault = {
    expr = gs.resolveSpec {
      inherit depsDefault depsGroups;
      includeGroups = [];
    };
    expected = depsDefault;
  };

  # ---------------------------------------------------------------
  # composeGroups
  # ---------------------------------------------------------------
  testComposeAddsGroupToExistingMember = {
    expr = gs.composeGroups {
      spec = {
        root = [];
        libA = ["dev"];
      };
      groups = {root = ["research"];};
    };
    expected = {
      root = ["research"];
      libA = ["dev"];
    };
  };

  testComposeIsIdempotentUnion = {
    expr = gs.composeGroups {
      spec = {libA = ["dev" "test"];};
      groups = {libA = ["dev"];};
    };
    expected = {libA = ["dev" "test"];};
  };

  testComposeEmptyIsIdentity = {
    expr = gs.composeGroups {
      spec = depsDefault;
      groups = {};
    };
    expected = depsDefault;
  };

  # ---------------------------------------------------------------
  # validateGroupSelection — success returns payload unchanged
  # ---------------------------------------------------------------
  testValidatePassesThroughPayload = {
    expr = gs.validateGroupSelection {
      inherit depsGroups;
      includeGroups = ["dev" "research"];
      groups = {root = ["research"];};
      payload = "SPEC";
    };
    expected = "SPEC";
  };

  testValidateIgnoresBoolIncludeGroups = {
    expr = gs.validateGroupSelection {
      inherit depsGroups;
      includeGroups = true;
      payload = "SPEC";
    };
    expected = "SPEC";
  };

  # ---------------------------------------------------------------
  # validateGroupSelection — failures throw with context
  # ---------------------------------------------------------------
  testValidateUnknownIncludeGroupThrows = {
    expr = gs.validateGroupSelection {
      inherit depsGroups;
      includeGroups = ["reserch"]; # typo
      payload = "SPEC";
    };
    expectedError.type = "ThrownError";
    expectedError.msg = "unknown group";
  };

  testValidateGroupsUnknownMemberThrows = {
    expr = gs.validateGroupSelection {
      inherit depsGroups;
      groups = {nope = ["dev"];};
      payload = "SPEC";
    };
    expectedError.type = "ThrownError";
    expectedError.msg = "not a workspace member";
  };

  testValidateGroupsUndefinedGroupForMemberThrows = {
    # libA does not define `research` (only root does).
    expr = gs.validateGroupSelection {
      inherit depsGroups;
      groups = {libA = ["research"];};
      payload = "SPEC";
    };
    expectedError.type = "ThrownError";
    expectedError.msg = "does not define";
  };

  # ---------------------------------------------------------------
  # isDevToolsEnvCandidate (via selectPythonEnvWithDevTools)
  # ---------------------------------------------------------------
  # provideDevTools = true selects a list-form env the heuristic would miss.
  testProvideDevToolsTrueSelectsListEnv = {
    expr = envSel.selectPythonEnvWithDevTools {
      pythonCfg.environments.ci = {
        editable = false;
        includeGroups = ["dev" "test"];
        provideDevTools = true;
      };
      pythonEnvOutputs.ci = "CI-DRV";
    };
    expected = "CI-DRV";
  };

  # provideDevTools = false rejects even an all-groups env; no workspace => null.
  testProvideDevToolsFalseRejects = {
    expr = envSel.selectPythonEnvWithDevTools {
      pythonCfg.environments.ci = {
        editable = false;
        includeGroups = true;
        provideDevTools = false;
      };
      pythonEnvOutputs.ci = "CI-DRV";
      pythonWorkspace = null;
    };
    expected = null;
  };

  # null provideDevTools falls back to the includeGroups == true heuristic.
  testHeuristicSelectsAllGroupsEnv = {
    expr = envSel.selectPythonEnvWithDevTools {
      pythonCfg.environments.ci = {
        editable = false;
        includeGroups = true;
      };
      pythonEnvOutputs.ci = "CI-DRV";
    };
    expected = "CI-DRV";
  };

  # list-form includeGroups WITHOUT the flag is not auto-discovered; with no
  # workspace to fall back to, selection is null (checks would build their own).
  testListEnvWithoutFlagNotDiscovered = {
    expr = envSel.selectPythonEnvWithDevTools {
      pythonCfg.environments.ci = {
        editable = false;
        includeGroups = ["dev" "test"];
      };
      pythonEnvOutputs.ci = "CI-DRV";
      pythonWorkspace = null;
    };
    expected = null;
  };
}
