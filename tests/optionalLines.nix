{
  lib,
  testHelpers,
}: let
  inherit (testHelpers.justHelpers) optionalLines;
in {
  # Test with condition true - should return lines
  testConditionTrue = {
    expr = optionalLines true ["line1" "line2" "line3"];
    expected = ["line1" "line2" "line3"];
  };

  # Test with condition false - should return empty list
  testConditionFalse = {
    expr = optionalLines false ["line1" "line2" "line3"];
    expected = [];
  };

  # Test with empty list and condition true
  testEmptyListConditionTrue = {
    expr = optionalLines true [];
    expected = [];
  };

  # Test with empty list and condition false
  testEmptyListConditionFalse = {
    expr = optionalLines false [];
    expected = [];
  };

  # Test with single line and condition true
  testSingleLineConditionTrue = {
    expr = optionalLines true ["only line"];
    expected = ["only line"];
  };

  # Test with single line and condition false
  testSingleLineConditionFalse = {
    expr = optionalLines false ["only line"];
    expected = [];
  };

  # Test with complex condition (non-null check)
  testComplexConditionNonNull = {
    expr = optionalLines ("value" != null) ["line"];
    expected = ["line"];
  };

  # Test with complex condition (null check)
  testComplexConditionNull = {
    expr = optionalLines (null != null) ["line"];
    expected = [];
  };

  # Test that lines can contain special characters
  testLinesWithSpecialChars = {
    expr = optionalLines true [
      "    indented line"
      "line with @special #chars"
      "line with \"quotes\""
    ];
    expected = [
      "    indented line"
      "line with @special #chars"
      "line with \"quotes\""
    ];
  };

  # Test use in list concatenation (realistic use case)
  testInListConcatenation = let
    baseLines = ["line1" "line2"];
    conditionalLines = optionalLines true ["line3" "line4"];
    result = baseLines ++ conditionalLines;
  in {
    expr = result;
    expected = ["line1" "line2" "line3" "line4"];
  };

  # Test use in list concatenation with false condition
  testInListConcatenationFalse = let
    baseLines = ["line1" "line2"];
    conditionalLines = optionalLines false ["line3" "line4"];
    result = baseLines ++ conditionalLines;
  in {
    expr = result;
    expected = ["line1" "line2"];
  };

  # Test chaining multiple optionalLines
  testChainingOptionalLines = let
    result =
      ["start"]
      ++ optionalLines true ["option1"]
      ++ optionalLines false ["option2"]
      ++ optionalLines true ["option3"]
      ++ ["end"];
  in {
    expr = result;
    expected = ["start" "option1" "option3" "end"];
  };

  # Test with condition using lib functions
  testWithLibFunctions = {
    expr = optionalLines (lib.hasPrefix "test" "test-string") ["matched"];
    expected = ["matched"];
  };

  # Test type consistency - always returns list
  testAlwaysReturnsList = let
    trueResult = optionalLines true ["line"];
    falseResult = optionalLines false ["line"];
  in {
    expr = lib.isList trueResult && lib.isList falseResult;
    expected = true;
  };
}
