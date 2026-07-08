{lib, ...}: let
  selectPythonEnvWithDevTools = {
    pythonCfg ? {},
    pythonWorkspace ? null,
    pythonEnvOutputs ? {},
  }: let
    configuredEnvs = pythonCfg.environments or {};

    isEditableEnv = envCfg: envCfg != null && (envCfg.editable or false);
    isNonEditableEnv = envCfg: envCfg != null && !isEditableEnv envCfg;

    # An env advertises itself as the check-tools provider (pytest/mypy/ruff)
    # either explicitly via `provideDevTools`, or — when that is unset — via the
    # historical heuristic `includeGroups == true`. The explicit flag is the
    # escape hatch for envs leaned down with a list-form includeGroups (e.g.
    # [ "dev" "test" ]), which the `== true` heuristic would otherwise miss.
    isDevToolsEnvCandidate = envCfg:
      isNonEditableEnv envCfg
      && (
        let
          provide = envCfg.provideDevTools or null;
        in
          if provide != null
          then provide
          else (envCfg.includeGroups or null) == true
      );

    hasDevEnv = configuredEnvs ? dev;
    devEnvConfig = configuredEnvs.dev or null;

    envWithDevTools =
      lib.findFirst
      (envName: isDevToolsEnvCandidate (configuredEnvs.${envName} or null))
      null
      (lib.attrNames configuredEnvs);

    selectedEnv =
      if hasDevEnv && isDevToolsEnvCandidate devEnvConfig
      then pythonEnvOutputs.dev or null
      else if envWithDevTools != null
      then pythonEnvOutputs.${envWithDevTools} or null
      else null;
  in
    if selectedEnv != null
    then selectedEnv
    else if pythonWorkspace != null
    then
      pythonWorkspace.mkEnv {
        name = "python-ci-checks";
        spec = pythonWorkspace.computeSpec {
          includeGroups = true;
        };
      }
    else null;
in {
  inherit selectPythonEnvWithDevTools;

  selectDevToolsPackage = {
    pythonCfg ? {},
    pythonWorkspace ? null,
    pythonEnvOutputs ? {},
    pythonDefaultEnv ? null,
    fallbackPackage,
  }: let
    pythonEnvWithDevTools = selectPythonEnvWithDevTools {
      inherit pythonCfg pythonWorkspace pythonEnvOutputs;
    };
  in
    if pythonEnvWithDevTools != null
    then pythonEnvWithDevTools
    else if pythonDefaultEnv != null
    then pythonDefaultEnv
    else fallbackPackage;
}
