{
  python3Packages,
  fetchFromGitHub,
  cudatoolkit,
  espeak,
  ffmpeg,
}:
with python3Packages; let
  name = "epub2tts";
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
    propagatedBuildInputs = [
      pip
      beautifulsoup4
      # deepspeed
      ebooklib
      # edge-tts
      fuzzywuzzy
      mutagen
      # newspaper3k
      nltk
      # noisereduce
      openai
      openai-whisper
      # pedalboard
      pydub
      pysbd
      python-Levenshtein
      requests
      torch
      torchaudio
      # TTS
      tqdm
      unidecode

      cudatoolkit
      espeak
      ffmpeg
    ];
  }
