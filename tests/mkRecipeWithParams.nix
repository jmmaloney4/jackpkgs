{
  lib,
  testHelpers,
}: let
  inherit (testHelpers.justHelpers) mkRecipeWithParams;
in {
  # Test recipe with single parameter
  testSingleParameter = {
    expr =
      mkRecipeWithParams "deploy" [''env="dev"''] "Deploy to environment" [
        "echo 'Deploying to {{env}}'"
        "kubectl apply -f {{env}}.yaml"
      ]
      false;
    expected = ''
      # Deploy to environment
      deploy env="dev":
          echo 'Deploying to {{env}}'
          kubectl apply -f {{env}}.yaml
    '';
  };

  # Test recipe with multiple parameters
  testMultipleParameters = {
    expr =
      mkRecipeWithParams "run" [''name=""'' ''args=""''] "Run with arguments" [
        "./script {{name}} {{args}}"
      ]
      false;
    expected = ''
      # Run with arguments
      run name="" args="":
          ./script {{name}} {{args}}
    '';
  };

  # Test recipe with no parameters (should work like mkRecipe)
  testNoParameters = {
    expr =
      mkRecipeWithParams "build" [] "Build the project" [
        "make build"
      ]
      false;
    expected = ''
      # Build the project
      build:
          make build
    '';
  };

  # Test recipe with parameter with default value
  testParameterWithDefault = {
    expr =
      mkRecipeWithParams "test" [''suite="all"''] "Run test suite" [
        "pytest {{suite}}"
      ]
      false;
    expected = ''
      # Run test suite
      test suite="all":
          pytest {{suite}}
    '';
  };

  # Test recipe with required parameter (empty string default)
  testRequiredParameter = {
    expr =
      mkRecipeWithParams "process" [''file=""''] "Process file" [
        "@echo 'Processing {{file}}'"
        "process-tool {{file}}"
      ]
      false;
    expected = ''
      # Process file
      process file="":
          @echo 'Processing {{file}}'
          process-tool {{file}}
    '';
  };

  # Test recipe with many parameters
  testManyParameters = {
    expr =
      mkRecipeWithParams "complex" [
        ''param1="default1"''
        ''param2=""''
        ''param3="value3"''
      ] "Complex recipe" [
        "echo {{param1}} {{param2}} {{param3}}"
      ]
      false;
    expected = ''
      # Complex recipe
      complex param1="default1" param2="" param3="value3":
          echo {{param1}} {{param2}} {{param3}}
    '';
  };

  # Test that parameter string is properly formatted
  testParameterFormatting = let
    result = mkRecipeWithParams "test" [''a="1"'' ''b="2"''] "Test" ["cmd"] false;
    lines = lib.splitString "\n" result;
    # Second line should be the recipe signature
    signatureLine = lib.elemAt lines 1;
  in {
    expr = signatureLine;
    expected = ''test a="1" b="2":'';
  };

  # Test recipe with shebang and parameters
  testShebangWithParameters = {
    expr =
      mkRecipeWithParams "script" [''mode="info"''] "Run script" [
        "#!/usr/bin/env bash"
        "set -euo pipefail"
        ''echo "Mode: {{mode}}"''
        ''if [ "{{mode}}" = "debug" ]; then''
        "    set -x"
        "fi"
      ]
      false;
    expected = ''
      # Run script
      script mode="info":
          #!/usr/bin/env bash
          set -euo pipefail
          echo "Mode: {{mode}}"
          if [ "{{mode}}" = "debug" ]; then
              set -x
          fi
    '';
  };

  # Test that empty params list doesn't add extra space
  testEmptyParamsNoSpace = let
    result = mkRecipeWithParams "test" [] "Test" ["cmd"] false;
    lines = lib.splitString "\n" result;
    signatureLine = lib.elemAt lines 1;
  in {
    # Should be "test:" not "test :"
    expr = signatureLine;
    expected = "test:";
  };

  # Test parameter with special characters in default value
  testParameterSpecialChars = {
    expr =
      mkRecipeWithParams "deploy" [''region="us-east-1"''] "Deploy to region" [
        "aws deploy --region {{region}}"
      ]
      false;
    expected = ''
      # Deploy to region
      deploy region="us-east-1":
          aws deploy --region {{region}}
    '';
  };

  # Test bash shebang recipe with echoCommands and parameters
  testShebangWithParametersAndEchoCommands = {
    expr =
      mkRecipeWithParams "verbose-script" [''env="dev"''] "Run verbose script" [
        "#!/usr/bin/env bash"
        "set -euo pipefail"
        ''echo "Deploying to {{env}}"''
        "kubectl apply -f {{env}}.yaml"
      ]
      true;
    expected = ''
      # Run verbose script
      verbose-script env="dev":
          #!/usr/bin/env bash
          set -euo pipefail
          set -x
          echo "Deploying to {{env}}"
          kubectl apply -f {{env}}.yaml
    '';
  };
}
