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
    description = "Set repo-local git user.name/email from GROKBOT_GIT_NAME/EMAIL or the latest Bot: trailer";
    mainProgram = "git-bot-identity";
  };
}
