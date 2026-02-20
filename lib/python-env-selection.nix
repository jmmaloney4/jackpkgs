{lib}: {
  selectPythonEnvWithDevTools = {
    pythonCfg ? {},
    pythonWorkspace ? null,
    pythonEnvOutputs ? {},
  }: let
    configuredEnvs = pythonCfg.environments or {};

    isEditableEnv = envCfg: envCfg != null && (envCfg.editable or false);
    isNonEditableEnv = envCfg: envCfg != null && !isEditableEnv envCfg;

    isCiEnvCandidate = envCfg:
      isNonEditableEnv envCfg
      && (envCfg.includeGroups or null) == true;

    hasDevEnv = configuredEnvs ? dev;
    devEnvConfig = configuredEnvs.dev or null;

    envWithGroups =
      lib.findFirst
      (envName: isCiEnvCandidate (configuredEnvs.${envName} or null))
      null
      (lib.attrNames configuredEnvs);

    selectedEnv =
      if hasDevEnv && isCiEnvCandidate devEnvConfig
      then pythonEnvOutputs.dev or null
      else if envWithGroups != null
      then pythonEnvOutputs.${envWithGroups} or null
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
