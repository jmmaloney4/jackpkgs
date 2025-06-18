{ lib, rustPlatform, fetchFromGitHub, pkg-config, openssl }:
rustPlatform.buildRustPackage rec {
  pname = "gpto";
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];
  doCheck = false;
  version = "0.2.2";

  src = fetchFromGitHub {
    owner = "alanvardy";
    repo = "gpto";
    rev = "v${version}";
    hash = "sha256-ZQwRvsVq3HDxgHqmJwlnzLme7DoonBjPnKZYOePRoNY=";
  };

  cargoHash = "sha256-4HT+hS5MFx1caicfZIaF4NOIjNKh0f+gUYrXB0S47eg=";

  meta = with lib; {
    description = "A tiny unofficial OpenAI client";
    homepage = "https://github.com/alanvardy/gpto";
    license = licenses.mit;
    mainProgram = "gpto";
  };
}
