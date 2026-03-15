defmodule SymphonyElixir.ReviewResultTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ReviewResult

  describe "parse/1 with structured JSON" do
    test "parses JSON review with dimensions" do
      json = """
      ```json
      {
        "overall_verdict": "changes_requested",
        "dimensions": [
          {"name": "correctness", "verdict": "pass", "severity": "critical"},
          {"name": "test_coverage", "verdict": "fail", "feedback": "Missing edge case tests", "severity": "high"},
          {"name": "code_quality", "verdict": "pass", "severity": "medium"}
        ]
      }
      ```
      """

      result = ReviewResult.parse(json)
      assert result.overall_verdict == :changes_requested
      assert length(result.dimensions) == 3
      assert Enum.at(result.dimensions, 1).name == "test_coverage"
      assert Enum.at(result.dimensions, 1).verdict == :fail
      assert Enum.at(result.dimensions, 1).feedback == "Missing edge case tests"
    end

    test "parses JSON review with approved verdict" do
      json = """
      ```json
      {"overall_verdict": "approved", "dimensions": []}
      ```
      """

      result = ReviewResult.parse(json)
      assert ReviewResult.approved?(result)
    end
  end

  describe "parse/1 with text fallback" do
    test "detects APPROVED signal" do
      result = ReviewResult.parse("Everything looks good.\n\nAPPROVED")
      assert ReviewResult.approved?(result)
      assert result.dimensions == []
    end

    test "detects CHANGES_REQUESTED signal" do
      result = ReviewResult.parse("Found issues.\n\nCHANGES_REQUESTED")
      refute ReviewResult.approved?(result)
    end

    test "defaults to changes_requested for safety" do
      result = ReviewResult.parse("Some review text without a clear verdict")
      refute ReviewResult.approved?(result)
    end

    test "detects LGTM signal" do
      result = ReviewResult.parse("LGTM, ship it!")
      assert ReviewResult.approved?(result)
    end
  end

  describe "approved?/1" do
    test "returns true for approved result" do
      result = %ReviewResult{overall_verdict: :approved}
      assert ReviewResult.approved?(result)
    end

    test "returns false for changes_requested" do
      result = %ReviewResult{overall_verdict: :changes_requested}
      refute ReviewResult.approved?(result)
    end
  end

  describe "format_feedback/1" do
    test "formats dimensional feedback" do
      result = %ReviewResult{
        overall_verdict: :changes_requested,
        dimensions: [
          %ReviewResult.Dimension{name: "correctness", verdict: :pass, severity: :critical},
          %ReviewResult.Dimension{
            name: "test_coverage",
            verdict: :fail,
            feedback: "Need more tests",
            severity: :high
          }
        ],
        iteration: 2,
        max_iterations: 3
      }

      feedback = ReviewResult.format_feedback(result)
      assert feedback =~ "CHANGES_REQUESTED"
      assert feedback =~ "correctness"
      assert feedback =~ "PASS"
      assert feedback =~ "test_coverage"
      assert feedback =~ "FAIL"
      assert feedback =~ "Need more tests"
      assert feedback =~ "Iteration 2/3"
    end

    test "handles empty dimensions" do
      result = %ReviewResult{overall_verdict: :approved}
      feedback = ReviewResult.format_feedback(result)
      assert feedback =~ "APPROVED"
      assert feedback =~ "No dimensional feedback"
    end
  end

  describe "failing_dimensions/1" do
    test "returns only failing dimensions" do
      result = %ReviewResult{
        overall_verdict: :changes_requested,
        dimensions: [
          %ReviewResult.Dimension{name: "correctness", verdict: :pass, severity: :medium},
          %ReviewResult.Dimension{name: "tests", verdict: :fail, severity: :high},
          %ReviewResult.Dimension{name: "security", verdict: :fail, severity: :critical}
        ]
      }

      failing = ReviewResult.failing_dimensions(result)
      assert length(failing) == 2
      assert Enum.all?(failing, fn d -> d.verdict == :fail end)
    end
  end

  describe "has_critical_failures?/1" do
    test "returns true when critical or high severity failures exist" do
      result = %ReviewResult{
        overall_verdict: :changes_requested,
        dimensions: [
          %ReviewResult.Dimension{name: "security", verdict: :fail, severity: :critical}
        ]
      }

      assert ReviewResult.has_critical_failures?(result)
    end

    test "returns false when only low/medium failures" do
      result = %ReviewResult{
        overall_verdict: :changes_requested,
        dimensions: [
          %ReviewResult.Dimension{name: "style", verdict: :fail, severity: :low}
        ]
      }

      refute ReviewResult.has_critical_failures?(result)
    end
  end
end
