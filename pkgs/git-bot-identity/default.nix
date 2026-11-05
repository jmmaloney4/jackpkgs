{
  writeShellApplication,
  coreutils,
}:
writeShellApplication {
  name = "git-bot-identity";
  runtimeInputs = [coreutils];
  text = builtins.readFile ./git-bot-identity.sh;
  meta = {
    description = "Print shell exports for bot git identity from required GROKBOT_GIT_* env (never touches git config)";
    mainProgram = "git-bot-identity";
  };
}
