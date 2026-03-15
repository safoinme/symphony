defmodule SymphonyElixir.ReviewResult do
  @moduledoc """
  Multi-dimensional review result with per-dimension verdicts.
  Supports structured JSON parsing with fallback to string matching.
  """

  alias __MODULE__

  defmodule Dimension do
    @moduledoc false

    @type verdict :: :pass | :fail
    @type severity :: :critical | :high | :medium | :low

    @type t :: %__MODULE__{
            name: String.t(),
            verdict: verdict(),
            feedback: String.t() | nil,
            severity: severity()
          }

    @enforce_keys [:name, :verdict]
    defstruct [:name, :verdict, :feedback, severity: :medium]
  end

  @type verdict :: :approved | :changes_requested

  @type t :: %__MODULE__{
          overall_verdict: verdict(),
          dimensions: [Dimension.t()],
          iteration: pos_integer(),
          max_iterations: pos_integer()
        }

  @enforce_keys [:overall_verdict]
  defstruct [:overall_verdict, dimensions: [], iteration: 1, max_iterations: 3]

  @approved_signals ["APPROVED", "LGTM", "APPROVE"]
  @rejected_signals ["CHANGES_REQUESTED", "REQUEST_CHANGES", "REJECT"]

  @spec parse(String.t()) :: t()
  def parse(review_text) when is_binary(review_text) do
    case parse_json_review(review_text) do
      {:ok, result} -> result
      :no_json -> parse_text_review(review_text)
    end
  end

  @spec approved?(t()) :: boolean()
  def approved?(%ReviewResult{overall_verdict: :approved}), do: true
  def approved?(%ReviewResult{}), do: false

  @spec format_feedback(t()) :: String.t()
  def format_feedback(%ReviewResult{dimensions: []} = result) do
    verdict_label = if approved?(result), do: "APPROVED", else: "CHANGES_REQUESTED"
    "## Review Verdict: #{verdict_label}\n\nNo dimensional feedback available."
  end

  def format_feedback(%ReviewResult{} = result) do
    verdict_label = if approved?(result), do: "APPROVED", else: "CHANGES_REQUESTED"

    dimension_lines =
      result.dimensions
      |> Enum.map(fn dim ->
        icon = if dim.verdict == :pass, do: "PASS", else: "FAIL"
        severity = "(#{dim.severity})"
        feedback = if dim.feedback, do: "\n  #{dim.feedback}", else: ""
        "- **#{dim.name}**: #{icon} #{severity}#{feedback}"
      end)
      |> Enum.join("\n")

    """
    ## Review Verdict: #{verdict_label}

    ### Dimensions
    #{dimension_lines}

    _Iteration #{result.iteration}/#{result.max_iterations}_
    """
  end

  @spec failing_dimensions(t()) :: [Dimension.t()]
  def failing_dimensions(%ReviewResult{dimensions: dimensions}) do
    Enum.filter(dimensions, fn dim -> dim.verdict == :fail end)
  end

  @spec has_critical_failures?(t()) :: boolean()
  def has_critical_failures?(%ReviewResult{} = result) do
    result
    |> failing_dimensions()
    |> Enum.any?(fn dim -> dim.severity in [:critical, :high] end)
  end

  # --- Private ---

  @json_fence_regex ~r/```json\s*\n([\s\S]*?)\n\s*```/

  defp parse_json_review(text) do
    case Regex.run(@json_fence_regex, text) do
      [_, json_block] -> decode_review_json(json_block)
      nil -> try_raw_json(text)
    end
  end

  defp try_raw_json(text) do
    trimmed = String.trim(text)

    if String.starts_with?(trimmed, "{") do
      decode_review_json(trimmed)
    else
      :no_json
    end
  end

  defp decode_review_json(json) do
    case Jason.decode(json) do
      {:ok, %{"overall_verdict" => verdict} = data} ->
        dimensions =
          data
          |> Map.get("dimensions", [])
          |> Enum.map(&parse_dimension/1)

        {:ok,
         %ReviewResult{
           overall_verdict: parse_verdict_string(verdict),
           dimensions: dimensions,
           iteration: Map.get(data, "iteration", 1),
           max_iterations: Map.get(data, "max_iterations", 3)
         }}

      {:ok, _} ->
        :no_json

      {:error, _} ->
        :no_json
    end
  end

  defp parse_dimension(dim) when is_map(dim) do
    %Dimension{
      name: Map.get(dim, "name", "unknown"),
      verdict: parse_dim_verdict(Map.get(dim, "verdict", "fail")),
      feedback: Map.get(dim, "feedback"),
      severity: parse_severity(Map.get(dim, "severity", "medium"))
    }
  end

  defp parse_dimension(_), do: %Dimension{name: "unknown", verdict: :fail}

  defp parse_text_review(text) do
    %ReviewResult{
      overall_verdict: parse_verdict_from_text(text),
      dimensions: [],
      iteration: 1,
      max_iterations: 3
    }
  end

  defp parse_verdict_from_text(text) do
    uppercased = String.upcase(text)

    cond do
      Enum.any?(@approved_signals, &String.contains?(uppercased, &1)) -> :approved
      Enum.any?(@rejected_signals, &String.contains?(uppercased, &1)) -> :changes_requested
      true -> :changes_requested
    end
  end

  defp parse_verdict_string(verdict) when is_binary(verdict) do
    case String.downcase(verdict) do
      "approved" -> :approved
      "lgtm" -> :approved
      "approve" -> :approved
      _ -> :changes_requested
    end
  end

  defp parse_verdict_string(_), do: :changes_requested

  defp parse_dim_verdict("pass"), do: :pass
  defp parse_dim_verdict("PASS"), do: :pass
  defp parse_dim_verdict(_), do: :fail

  defp parse_severity("critical"), do: :critical
  defp parse_severity("high"), do: :high
  defp parse_severity("medium"), do: :medium
  defp parse_severity("low"), do: :low
  defp parse_severity(_), do: :medium
end
