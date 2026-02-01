{
  lib,
  python3Packages,
  fetchFromGitHub,
}:
python3Packages.buildPythonApplication rec {
  pname = "npm-lockfile-fix";
  version = "0.1.1";
  pyproject = true;

  src = fetchFromGitHub {
    owner = "jeslie0";
    repo = "npm-lockfile-fix";
    rev = "v${version}";
    hash = "sha256-P93OowrVkkOfX5XKsRsg0c4dZLVn2ZOonJazPmHdD7g=";
  };

  build-system = [python3Packages.setuptools];
  propagatedBuildInputs = [python3Packages.requests];

  meta = {
    description = "Add missing integrity and resolved fields to npm workspace lockfiles";
    homepage = "https://github.com/jeslie0/npm-lockfile-fix";
    license = lib.licenses.mit;
    mainProgram = "npm-lockfile-fix";
  };
}
