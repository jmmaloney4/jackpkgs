{
  python3Packages,
  fetchFromGitHub,
  cudatoolkit,
  espeak,
  ffmpeg,
}:
with python3Packages; let
  name = "epub2tts";
in buildPythonApplication {
  inherit name;
  format = "setuptools";
  src = fetchFromGitHub {
    owner = "aedocw";
    repo = "epub2tts";
    rev = "bfc1fc8b51dd9216d006a3e64c11cf7eb79e5a03";
    sha256 = "";
  };
  propagatedBuildInputs = [
    cudatoolkit
    espeak
    ffmpeg
  ];
}