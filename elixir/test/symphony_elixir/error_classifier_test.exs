defmodule SymphonyElixir.ErrorClassifierTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.ErrorClassifier

  describe "classify/1" do
    test "classifies rate limit errors" do
      assert :rate_limit == ErrorClassifier.classify("rate limit exceeded")
      assert :rate_limit == ErrorClassifier.classify("Too Many Requests")
      assert :rate_limit == ErrorClassifier.classify({:rate_limit, "slow down"})
      assert :rate_limit == ErrorClassifier.classify(:rate_limited)
      assert :rate_limit == ErrorClassifier.classify("error 429: throttled")
    end

    test "classifies context overflow errors" do
      assert :context_overflow == ErrorClassifier.classify("context length exceeded")
      assert :context_overflow == ErrorClassifier.classify({:context_overflow, "too large"})
      assert :context_overflow == ErrorClassifier.classify(:context_overflow)
      assert :context_overflow == ErrorClassifier.classify("context too long for model")
      assert :context_overflow == ErrorClassifier.classify("context maximum exceeded")
    end

    test "classifies validation errors" do
      assert :validation == ErrorClassifier.classify("validation error in request")
      assert :validation == ErrorClassifier.classify({:validation_error, "bad field"})
      assert :validation == ErrorClassifier.classify("invalid request body")
      assert :validation == ErrorClassifier.classify("malformed input")
    end

    test "classifies tool failure errors" do
      assert :tool_failure == ErrorClassifier.classify({:tool_failure, "bash failed"})
      assert :tool_failure == ErrorClassifier.classify("tool error: command not found")
    end

    test "classifies non-retriable errors" do
      assert :non_retriable == ErrorClassifier.classify({:authentication_error, "bad token"})
      assert :non_retriable == ErrorClassifier.classify("permission denied")
      assert :non_retriable == ErrorClassifier.classify("unauthorized access 401")
      assert :non_retriable == ErrorClassifier.classify("forbidden 403")
    end

    test "classifies unknown errors" do
      assert :unknown == ErrorClassifier.classify("something weird happened")
      assert :unknown == ErrorClassifier.classify({:unexpected, :crash})
      assert :unknown == ErrorClassifier.classify(42)
    end

    test "classifies RuntimeError by message" do
      assert :rate_limit == ErrorClassifier.classify(%RuntimeError{message: "rate limit hit"})
    end
  end

  describe "retry_strategy/2" do
    test "rate limit gets fixed 60s delay" do
      assert {:retry, 60_000} = ErrorClassifier.retry_strategy(:rate_limit, 1)
      assert {:retry, 60_000} = ErrorClassifier.retry_strategy(:rate_limit, 5)
    end

    test "tool failure gets exponential backoff" do
      {:retry, delay_1} = ErrorClassifier.retry_strategy(:tool_failure, 1)
      {:retry, delay_3} = ErrorClassifier.retry_strategy(:tool_failure, 3)
      assert delay_3 > delay_1
    end

    test "unknown gets exponential backoff" do
      {:retry, delay} = ErrorClassifier.retry_strategy(:unknown, 1)
      assert delay > 0
    end

    test "context overflow is not retriable" do
      assert :no_retry = ErrorClassifier.retry_strategy(:context_overflow, 1)
    end

    test "validation is not retriable" do
      assert :no_retry = ErrorClassifier.retry_strategy(:validation, 1)
    end

    test "non_retriable is not retriable" do
      assert :no_retry = ErrorClassifier.retry_strategy(:non_retriable, 1)
    end
  end
end
