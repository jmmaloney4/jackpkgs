{
  python3Packages,
  fetchFromGitHub,
  pkg-config-unwrapped,
  cudatoolkit,
  espeak,
  ffmpeg,
}:
with python3Packages; let
  name = "epub2tts";

  pypiPackage = {
    pname,
    version,
    sha256,
    propagatedBuildInputs ? [],
  }:
    buildPythonPackage {
      inherit pname version propagatedBuildInputs;
      src = fetchPypi {
        inherit pname version sha256;
      };
    };
in
  buildPythonApplication {
    inherit name;
    format = "setuptools";

    src = fetchFromGitHub {
      owner = "aedocw";
      repo = "epub2tts";
      rev = "bfc1fc8b51dd9216d006a3e64c11cf7eb79e5a03";
      sha256 = "sha256-zNidOM37YenkKSTtNm/NrjdBbBcg+cxZ24NfA7r+Uyg=";
    };

    propagatedBuildInputs = let
      deepspeed = pypiPackage {
        pname = "deepspeed";
        version = "0.14.0";
        sha256 = "sha256-ihQLaT+Zl3ZjfvAEURJDR5eV9tPaLj+SwdUIt1YYORc=";
        propagatedBuildInputs = [pip];
      };
      edge-tts = pypiPackage {
        pname = "edge-tts";
        version = "6.1.10";
        sha256 = "sha256-cKSfMu12bqQFuNKkTvEkgFNJ0pbBpWoiCwr/HiAviJE=";
        propagatedBuildInputs = [pip certifi];
      };
      newspaper3k = pypiPackage {
        pname = "newspaper3k";
        version = "0.2.8";
        sha256 = "sha256-nxvT4ftI9ADHFav4dcx7Cme33c2H9Qya7rj8u72QBPs=";
        propagatedBuildInputs = [pip];
      };
      noisereduce = pypiPackage {
        pname = "noisereduce";
        version = "3.0.2";
        sha256 = "sha256-ClMtIiOYboKVrleo+G+0aZpHdjaEEjf/qMMjyVm9nAs=";
        propagatedBuildInputs = [pip tqdm numpy];
      };
      pedalboard = buildPythonPackage {
        name = "pedalboard";
        src = fetchFromGitHub {
          owner = "spotify";
          repo = "pedalboard";
          rev = "c3f44ba7740a629a11298ad90ec20602f25d3fdd";
          sha256 = "sha256-MIJ9BpqnG5SoyO/mKn7NpLJV2e2cwNvJ/LK+A/jUGRQ=";
        };
        propagatedBuildInputs = [
          pybind11
          pkgconfig
          (freetype-py.overridePythonAttrs
            (old: {
              propagatedBuildInputs =
                old.propagatedBuildInputs
                ++ [
                  pkg-config-unwrapped
                ];
            }))
          pkg-config-unwrapped
        ];
      };
      TTS = pypiPackage {
        pname = "TTS";
        version = "0.22.0";
        sha256 = "sha256-uREZ2n/yrns9rnMo7fmvTbO0jEDrTOFdEe2PXum9cIY=";
        propagatedBuildInputs = [pip packaging numpy cython];
      };
    in [
      pip
      packaging

      beautifulsoup4
      deepspeed
      ebooklib
      edge-tts
      fuzzywuzzy
      mutagen
      newspaper3k
      nltk
      noisereduce
      openai
      openai-whisper
      pedalboard
      pydub
      pysbd
      python-Levenshtein
      requests
      torch
      torchaudio
      TTS
      tqdm
      unidecode

      cudatoolkit
      espeak
      ffmpeg
    ];
  }
