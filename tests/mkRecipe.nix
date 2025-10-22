{
  lib,
  testHelpers,
}: let
  inherit (testHelpers.justHelpers) mkRecipe;
in {
  # Test basic recipe with single command
  testBasicRecipeSingleCommand = {
    expr = mkRecipe "build" "Build the project" ["make build"] false;
    expected = ''
      # Build the project
      build:
          make build
    '';
  };

  # Test recipe with multiple commands
  testRecipeMultipleCommands = {
    expr =
      mkRecipe "deploy" "Deploy to production" [
        "echo 'Building...'"
        "make build"
        "echo 'Deploying...'"
        "make deploy"
      ]
      false;
    expected = ''
      # Deploy to production
      deploy:
          echo 'Building...'
          make build
          echo 'Deploying...'
          make deploy
    '';
  };

  # Test recipe with no commands (edge case)
  testRecipeNoCommands = {
    expr = mkRecipe "empty" "Empty recipe" [] false;
    expected = ''
      # Empty recipe
      empty:
    '';
  };

  # Test recipe with special characters in comment
  testRecipeSpecialCharsInComment = {
    expr = mkRecipe "test" "Run tests (with special chars: @#$)" ["npm test"] false;
    expected = ''
      # Run tests (with special chars: @#$)
      test:
          npm test
    '';
  };

  # Test recipe with command containing interpolation syntax
  testRecipeWithInterpolation = {
    expr = mkRecipe "run" "Run with args" ["./script {{args}}"] false;
    expected = ''
      # Run with args
      run:
          ./script {{args}}
    '';
  };

  # Test that commands are properly indented with 4 spaces
  testCommandIndentation = let
    result = mkRecipe "test" "Test" ["command"] false;
    lines = lib.splitString "\n" result;
    # Third line should be the command (after comment and recipe name)
    commandLine = lib.elemAt lines 2;
  in {
    expr = lib.hasPrefix "    " commandLine && !lib.hasPrefix "     " commandLine;
    expected = true;
  };

  # Test that recipe produces trailing blank line
  testTrailingBlankLine = let
    result = mkRecipe "test" "Test" ["command"] false;
    lines = lib.splitString "\n" result;
  in {
    expr = lib.last lines;
    expected = "";
  };

  # Test recipe name appears on second line
  testRecipeNamePosition = let
    result = mkRecipe "my-recipe" "My Recipe" ["cmd"] false;
    lines = lib.splitString "\n" result;
  in {
    expr = lib.elemAt lines 1;
    expected = "my-recipe:";
  };

  # Test comment appears on first line
  testCommentPosition = let
    result = mkRecipe "my-recipe" "My Comment" ["cmd"] false;
    lines = lib.splitString "\n" result;
  in {
    expr = lib.elemAt lines 0;
    expected = "# My Comment";
  };

  # Test recipe with command containing backslashes
  testRecipeWithBackslashes = {
    expr =
      mkRecipe "multiline" "Multiline command" [
        ''echo "line 1" \''
        "&& echo \"line 2\""
      ]
      false;
    expected = ''
      # Multiline command
      multiline:
          echo "line 1" \
          && echo "line 2"
    '';
  };

  # Test recipe with @ prefix (silent command in justfiles)
  testRecipeWithSilentCommand = {
    expr = mkRecipe "silent" "Silent command" ["@echo 'hidden'"] false;
    expected = ''
      # Silent command
      silent:
          @echo 'hidden'
    '';
  };

  # Test recipe with just command invocation
  testRecipeWithJustInvocation = {
    expr = mkRecipe "alias" "Alias for another recipe" ["@just build"] false;
    expected = ''
      # Alias for another recipe
      alias:
          @just build
    '';
  };

  # Test shebang recipe with bash
  testShebangRecipeBash = {
    expr =
      mkRecipe "script" "Run bash script" [
        "#!/usr/bin/env bash"
        "set -euo pipefail"
        "echo 'hello world'"
      ]
      false;
    expected = ''
      # Run bash script
      script:
          #!/usr/bin/env bash
          set -euo pipefail
          echo 'hello world'
    '';
  };

  # Test shebang recipe with python
  testShebangRecipePython = {
    expr =
      mkRecipe "pyscript" "Run python script" [
        "#!/usr/bin/env python3"
        "print('hello from python')"
      ]
      false;
    expected = ''
      # Run python script
      pyscript:
          #!/usr/bin/env python3
          print('hello from python')
    '';
  };

  # Test shebang recipe with conditional logic
  testShebangRecipeConditional = {
    expr =
      mkRecipe "conditional" "Conditional script" [
        "#!/usr/bin/env bash"
        "set -euo pipefail"
        ''if [ -z "$VAR" ]; then''
        "    echo 'VAR is empty'"
        "else"
        "    echo 'VAR is set'"
        "fi"
      ]
      false;
    expected = ''
      # Conditional script
      conditional:
          #!/usr/bin/env bash
          set -euo pipefail
          if [ -z "$VAR" ]; then
              echo 'VAR is empty'
          else
              echo 'VAR is set'
          fi
    '';
  };

  # Test bash shebang recipe with echoCommands enabled
  testShebangBashWithEchoCommands = {
    expr =
      mkRecipe "verbose-script" "Run bash script with command echoing" [
        "#!/usr/bin/env bash"
        "set -euo pipefail"
        "echo 'hello world'"
        "echo 'goodbye world'"
      ]
      true;
    expected = ''
      # Run bash script with command echoing
      verbose-script:
          #!/usr/bin/env bash
          set -euo pipefail
          set -x
          echo 'hello world'
          echo 'goodbye world'
    '';
  };

  # Test that echoCommands only affects bash shebangs
  testEchoCommandsOnlyBash = {
    expr =
      mkRecipe "python-script" "Python script with echoCommands" [
        "#!/usr/bin/env python3"
        "print('hello')"
      ]
      true;
    expected = ''
      # Python script with echoCommands
      python-script:
          #!/usr/bin/env python3
          print('hello')
    '';
  };

  # Test echoCommands with no shebang (should be ignored)
  testEchoCommandsNoShebang = {
    expr =
      mkRecipe "no-shebang" "Regular recipe with echoCommands" [
        "echo 'hello'"
      ]
      true;
    expected = ''
      # Regular recipe with echoCommands
      no-shebang:
          echo 'hello'
    '';
  };

  # Test echoCommands with bash shebang but no set command
  testEchoCommandsNoSetCommand = {
    expr =
      mkRecipe "bash-no-set" "Bash without set command" [
        "#!/usr/bin/env bash"
        "echo 'hello'"
      ]
      true;
    expected = ''
      # Bash without set command
      bash-no-set:
          #!/usr/bin/env bash
          echo 'hello'
    '';
  };
}
