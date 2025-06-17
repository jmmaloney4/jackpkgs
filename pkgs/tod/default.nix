{ lib, rustPlatform, fetchFromGitHub, stdenv, pkg-config, openssl }:

rustPlatform.buildRustPackage rec {
  pname = "tod";
  version = "0.8.0"; # update with latest release

  src = fetchFromGitHub {
    owner = "alanvardy";
    repo = "tod";
    rev = "v${version}";
    # Update sha256 with: nix-prefetch-url --unpack https://github.com/alanvardy/tod/archive/refs/tags/v${version}.tar.gz
    # sha256 = "0fni15hqhmxcdp5nz03bi5kis8sh2pg4h8wxa73mcizj6waimyvg";
    sha256 = "sha256-b/saFTfyR1bHUZ0jSN4VUCMdZ4lrgG/LbaxXiGEJ0To=";
  };

  # cargoHash = "sha256-0l3s986lc6vdzz77hgsgicdcz0rr032ivl4z2rsxsldibwf0bsmv";
  cargoHash = "sha256-5lBVjYpViSpU2ByC7zD/+TY6zdm7cpB7igwnL4oFPDY=";

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ openssl ];

  # Skip tests that try to create config files in directories that don't exist in Nix sandbox
  checkFlags = [
    "--skip" "lists::tests::test_label"
    "--skip" "filters::tests::test_get_next_task"
    "--skip" "projects::tests::test_get_next_task"
  ];

  meta = with lib; {
    description = "Command line interface for Todoist";
    homepage = "https://github.com/alanvardy/tod";
    license = licenses.mit;
    maintainers = with maintainers; [ ];
    platforms = platforms.all;
    mainProgram = "tod";
  };
}
