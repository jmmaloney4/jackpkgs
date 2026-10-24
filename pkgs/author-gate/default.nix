{
  writeShellApplication,
  git,
  gnugrep,
  gnused,
  coreutils,
}:
writeShellApplication {
  name = "author-gate";
  runtimeInputs = [git gnugrep gnused coreutils];
  # SC2016: we print a literal `git rebase --exec` snippet for humans.
  excludeShellChecks = ["SC2016"];
  text = builtins.readFile ./author-gate.sh;
  meta = {
    description = "Fail if any commit in the merge-base range is authored or committed as cursoragent@cursor.com";
    mainProgram = "author-gate";
  };
}
