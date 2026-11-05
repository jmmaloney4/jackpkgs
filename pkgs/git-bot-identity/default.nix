{
  writeShellApplication,
  git,
  gnused,
  coreutils,
}:
writeShellApplication {
  name = "git-bot-identity";
  runtimeInputs = [git gnused coreutils];
  # SC2016: warning text mentions a literal `Bot:` trailer pattern.
  excludeShellChecks = ["SC2016"];
  text = builtins.readFile ./git-bot-identity.sh;
  meta = {
    description = "Print shell exports for bot git identity (GROKBOT_GIT_* and GIT_AUTHOR_*/COMMITTER_*) without touching git config";
    mainProgram = "git-bot-identity";
  };
}
