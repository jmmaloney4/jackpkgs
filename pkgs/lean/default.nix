{
  gnupatch,
  python3Packages,
}:
with python3Packages; let
  pname = "lean";
  version = "1.0.196";
in
  (buildPythonApplication {
    format = "setuptools";
    inherit pname version;
    nativeBuildInputs = [setuptools-scm];
    src = fetchPypi {
      inherit pname version;
      sha256 = "sha256-8WMBczr5/ibX5ckXLff0nTCGygOOslVzk2zj0QTUbhs=";
      # python = "py3";
    };
    propagatedBuildInputs = let
      maskpass = let
        pname = "maskpass";
        version = "0.3.7";
      in
        buildPythonApplication {
          inherit pname version;
          src = fetchPypi {
            inherit pname version;
            sha256 = "sha256-c0SIVhR6YRy3ydmP9Bfx5ViEQZ4IZFBFhODbnGpXtgw=";
          };
          checkPhase = ''
            runHook preCheck
            # ${pkgs.python3.interpreter} -m unittest
            runHook postCheck
          '';
        };
    in [
      click
      cryptography
      docker
      json5
      lxml-stubs
      maskpass
      pip
      pydantic
      pyfakefs
      pytest
      responses
      rich
      setuptools
    ];
    checkPhase = ''
      runHook preCheck
      # ${pkgs.python3.interpreter} -m unittest
      runHook postCheck
    '';
  })
  .overridePythonAttrs (old: {
    # we have to patch in postInstall for the wheel to be extracted to $out.
    # actually, we could probably set preferWheel to false for this package too...
    postInstall =
      (old.postInstall or "")
      + ''
        ${lib.getExe' gnupatch "patch"} -ruN -p0 -d $out -i ${./lean.patch}
      '';
  })
