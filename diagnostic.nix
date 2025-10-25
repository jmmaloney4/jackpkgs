# Diagnostic script for Python overlay precedence investigation
# Run with: nix eval --impure --json -f diagnostic.nix | jq
let
  flake = builtins.getFlake (toString ./.);
  system = builtins.currentSystem;  # Auto-detect system
  
  # Get the perSystem config if it exists
  hasPerSystem = flake.outputs ? legacyPackages && flake.outputs.legacyPackages ? ${system};
  
  config = 
    if hasPerSystem 
    then flake.outputs.legacyPackages.${system}
    else throw "No legacyPackages for system ${system}";
  
  # Check if pythonWorkspace exists
  hasPythonWorkspace = config ? pythonWorkspace;
  
  workspace = 
    if hasPythonWorkspace 
    then config.pythonWorkspace.workspace
    else null;
    
  pythonSet = 
    if hasPythonWorkspace 
    then config.pythonWorkspace.pythonSet
    else null;

  # Helper to safely get version
  getVersion = pkg: pkg.version or "not-found";
  
  # Gather all diagnostic data
  diagnostics = {
    system = system;
    hasPythonWorkspace = hasPythonWorkspace;
    
    # Workspace diagnostics
    workspaceLoaded = workspace != null;
    workspaceHasTypingExtensions = 
      if workspace != null 
      then builtins.hasAttr "typing-extensions" workspace.deps.default
      else false;
    workspaceDeps = 
      if workspace != null 
      then builtins.attrNames workspace.deps.default
      else [];
    
    # Python set diagnostics
    pythonSetLoaded = pythonSet != null;
    pythonSetTypingExtensionsVersion = 
      if pythonSet != null && pythonSet ? typing-extensions
      then getVersion pythonSet.typing-extensions
      else "not-found-in-pythonSet";
    
    # Check different scopes
    pythonPkgsBuildHostVersion = 
      if pythonSet != null && pythonSet ? pythonPkgsBuildHost && pythonSet.pythonPkgsBuildHost ? typing-extensions
      then getVersion pythonSet.pythonPkgsBuildHost.typing-extensions
      else "not-found-in-buildHost";
      
    pythonPkgsHostHostVersion = 
      if pythonSet != null && pythonSet ? pythonPkgsHostHost && pythonSet.pythonPkgsHostHost ? typing-extensions
      then getVersion pythonSet.pythonPkgsHostHost.typing-extensions  
      else "not-found-in-hostHost";
    
    # Additional checks
    pythonSetAttributes = 
      if pythonSet != null 
      then builtins.attrNames pythonSet
      else [];
  };
in
  diagnostics

