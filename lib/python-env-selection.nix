{lib, ...}: {
  selectPythonEnvWithDevTools = {
    pythonCfg ? {},
    pythonWorkspace ? null,
    pythonEnvOutputs ? {},
  }: let
    configuredEnvs = pythonCfg.environments or {};

    isEditableEnv = envCfg: envCfg != null && (envCfg.editable or false);
    isNonEditableEnv = envCfg: envCfg != null && !isEditableEnv envCfg;

    isDevToolsEnvCandidate = envCfg:
      isNonEditableEnv envCfg
      && (envCfg.includeGroups or null) == true;

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
}
