defmodule SymphonyElixir.ErrorClassifier do
  @moduledoc """
  Classifies agent errors into categories with differentiated retry strategies.
  Rate limits get fixed delays, context overflow and validation errors are non-retriable,
  and unknown errors get exponential backoff.
  """

  @type error_class ::
          :rate_limit
          | :context_overflow
          | :validation
          | :tool_failure
          | :non_retriable
          | :unknown

  @rate_limit_delay_ms 60_000
  @base_backoff_ms 10_000

  @spec classify(term()) :: error_class()
  def classify(reason) when is_binary(reason) do
    classify_string(String.downcase(reason))
  end

  def classify({:rate_limit, _}), do: :rate_limit
  def classify({:rate_limited, _}), do: :rate_limit
  def classify(:rate_limited), do: :rate_limit

  def classify({:context_overflow, _}), do: :context_overflow
  def classify({:context_length_exceeded, _}), do: :context_overflow
  def classify(:context_overflow), do: :context_overflow

  def classify({:validation_error, _}), do: :validation
  def classify({:invalid_request, _}), do: :validation

  def classify({:tool_failure, _}), do: :tool_failure
  def classify({:tool_error, _}), do: :tool_failure

  def classify({:authentication_error, _}), do: :non_retriable
  def classify({:permission_denied, _}), do: :non_retriable
  def classify(:authentication_error), do: :non_retriable

  def classify(%RuntimeError{message: message}), do: classify(message)

  def classify(reason) when is_atom(reason) do
    classify_string(Atom.to_string(reason))
  end

  def classify({tag, details}) when is_atom(tag) do
    tag_str = Atom.to_string(tag)
    details_str = if is_binary(details), do: details, else: inspect(details)
    classify_string(String.downcase(tag_str <> " " <> details_str))
  end

  def classify(_reason), do: :unknown

  @spec retry_strategy(error_class(), pos_integer()) :: {:retry, non_neg_integer()} | :no_retry
  def retry_strategy(:rate_limit, _attempt), do: {:retry, @rate_limit_delay_ms}

  def retry_strategy(:tool_failure, attempt), do: {:retry, exponential_backoff(attempt)}

  def retry_strategy(:unknown, attempt), do: {:retry, exponential_backoff(attempt)}

  def retry_strategy(:context_overflow, _attempt), do: :no_retry

  def retry_strategy(:validation, _attempt), do: :no_retry

  def retry_strategy(:non_retriable, _attempt), do: :no_retry

  # --- Private ---

  defp classify_string(text) do
    cond do
      rate_limit_pattern?(text) -> :rate_limit
      context_overflow_pattern?(text) -> :context_overflow
      validation_pattern?(text) -> :validation
      tool_failure_pattern?(text) -> :tool_failure
      non_retriable_pattern?(text) -> :non_retriable
      true -> :unknown
    end
  end

  defp rate_limit_pattern?(text) do
    String.contains?(text, ["rate limit", "rate_limit", "too many requests", "429", "throttl"])
  end

  defp context_overflow_pattern?(text) do
    String.contains?(text, "context") and
      String.contains?(text, ["overflow", "length exceeded", "too long", "maximum"])
  end

  defp validation_pattern?(text) do
    String.contains?(text, ["validation", "invalid request", "malformed"])
  end

  defp tool_failure_pattern?(text) do
    String.contains?(text, "tool") and String.contains?(text, ["fail", "error"])
  end

  defp non_retriable_pattern?(text) do
    String.contains?(text, [
      "authentication",
      "permission denied",
      "unauthorized",
      "forbidden",
      "401",
      "403"
    ])
  end

  defp exponential_backoff(attempt) when is_integer(attempt) and attempt > 0 do
    import Bitwise, only: [<<<: 2]
    max_delay_power = min(attempt - 1, 10)
    @base_backoff_ms * (1 <<< max_delay_power)
  end

  defp exponential_backoff(_attempt), do: @base_backoff_ms
end
