{
  lib,
  makeWrapper,
  python3Packages,
}:
python3Packages.stdenv.mkDerivation {
  pname = "pulumi-drift-report";
  version = "0.0.1";
  src = ../../tools/pulumi-drift-report;

  nativeBuildInputs = [makeWrapper];
  dontBuild = true;
  doCheck = true;
  nativeCheckInputs = [python3Packages.pytest];

  checkPhase = ''
    pytest -q tests
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/pulumi-drift-report"
    cp -r src "$out/lib/pulumi-drift-report/"
    cp pyproject.toml "$out/lib/pulumi-drift-report/"
    makeWrapper ${python3Packages.python.interpreter} "$out/bin/pulumi-drift-report" \
      --set PYTHONPATH "$out/lib/pulumi-drift-report/src" \
      --add-flags -m \
      --add-flags jmmaloney4.tools.pulumi_drift_report
    runHook postInstall
  '';

  meta = {
    description = "Report Pulumi preview and refresh changes across every stack in a checkout";
    homepage = "https://github.com/jmmaloney4/jackpkgs";
    license = lib.licenses.mit;
    platforms = lib.platforms.unix;
    mainProgram = "pulumi-drift-report";
  };
}
