{
  lib,
  testHelpers,
}: let
  inherit (testHelpers.justHelpers) mkRecipe;
in {
  # Test basic recipe with single command
  testBasicRecipeSingleCommand = {
    expr = mkRecipe "build" "Build the project" ["make build"];
    expected = ''
      # Build the project
      build:
          make build
    '';
  };

  # Test recipe with multiple commands
  testRecipeMultipleCommands = {
    expr = mkRecipe "deploy" "Deploy to production" [
      "echo 'Building...'"
      "make build"
      "echo 'Deploying...'"
      "make deploy"
    ];
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
    expr = mkRecipe "empty" "Empty recipe" [];
    expected = ''
      # Empty recipe
      empty:
    '';
  };

  # Test recipe with special characters in comment
  testRecipeSpecialCharsInComment = {
    expr = mkRecipe "test" "Run tests (with special chars: @#$)" ["npm test"];
    expected = ''
      # Run tests (with special chars: @#$)
      test:
          npm test
    '';
  };

  # Test recipe with command containing interpolation syntax
  testRecipeWithInterpolation = {
    expr = mkRecipe "run" "Run with args" ["./script {{args}}"];
    expected = ''
      # Run with args
      run:
          ./script {{args}}
    '';
  };

  # Test that commands are properly indented with 4 spaces
  testCommandIndentation = let
    result = mkRecipe "test" "Test" ["command"];
    lines = lib.splitString "\n" result;
    # Third line should be the command (after comment and recipe name)
    commandLine = lib.elemAt lines 2;
  in {
    expr = lib.hasPrefix "    " commandLine && !lib.hasPrefix "     " commandLine;
    expected = true;
  };

  # Test that recipe produces trailing blank line
  testTrailingBlankLine = let
    result = mkRecipe "test" "Test" ["command"];
    lines = lib.splitString "\n" result;
  in {
    expr = lib.last lines;
    expected = "";
  };

  # Test recipe name appears on second line
  testRecipeNamePosition = let
    result = mkRecipe "my-recipe" "My Recipe" ["cmd"];
    lines = lib.splitString "\n" result;
  in {
    expr = lib.elemAt lines 1;
    expected = "my-recipe:";
  };

  # Test comment appears on first line
  testCommentPosition = let
    result = mkRecipe "my-recipe" "My Comment" ["cmd"];
    lines = lib.splitString "\n" result;
  in {
    expr = lib.elemAt lines 0;
    expected = "# My Comment";
  };

  # Test recipe with command containing backslashes
  testRecipeWithBackslashes = {
    expr = mkRecipe "multiline" "Multiline command" [
      ''echo "line 1" \''
      "&& echo \"line 2\""
    ];
    expected = ''
      # Multiline command
      multiline:
          echo "line 1" \
          && echo "line 2"
    '';
  };

  # Test recipe with @ prefix (silent command in justfiles)
  testRecipeWithSilentCommand = {
    expr = mkRecipe "silent" "Silent command" ["@echo 'hidden'"];
    expected = ''
      # Silent command
      silent:
          @echo 'hidden'
    '';
  };

  # Test recipe with just command invocation
  testRecipeWithJustInvocation = {
    expr = mkRecipe "alias" "Alias for another recipe" ["@just build"];
    expected = ''
      # Alias for another recipe
      alias:
          @just build
    '';
  };

  # Test shebang recipe with bash
  testShebangRecipeBash = {
    expr = mkRecipe "script" "Run bash script" [
      "#!/usr/bin/env bash"
      "set -euo pipefail"
      "echo 'hello world'"
    ];
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
    expr = mkRecipe "pyscript" "Run python script" [
      "#!/usr/bin/env python3"
      "print('hello from python')"
    ];
    expected = ''
      # Run python script
      pyscript:
          #!/usr/bin/env python3
          print('hello from python')
    '';
  };

  # Test shebang recipe with conditional logic
  testShebangRecipeConditional = {
    expr = mkRecipe "conditional" "Conditional script" [
      "#!/usr/bin/env bash"
      "set -euo pipefail"
      ''if [ -z "$VAR" ]; then''
      "    echo 'VAR is empty'"
      "else"
      "    echo 'VAR is set'"
      "fi"
    ];
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
}
