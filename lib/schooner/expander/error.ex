defmodule Schooner.Expander.Error do
  @moduledoc """
  Exception raised by the expander for malformed macro forms, failed
  pattern matches, and other expansion-time failures. `:location` is the
  `Schooner.Location` of the form being expanded, or `nil`.
  """

  alias Schooner.Location

  defexception [:reason, :message, :location]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    location = Keyword.get(opts, :location)

    %__MODULE__{
      reason: reason,
      location: location,
      message: Location.prefix(location) <> format(reason)
    }
  end

  defp format({:bad_syntax, name}), do: "malformed `#{name}` form"

  defp format({:bad_template, reason}), do: "malformed macro template: #{reason}"
  defp format({:bad_pattern, reason}), do: "malformed macro pattern: #{reason}"
  defp format(:duplicate_pattern_var), do: "duplicate pattern variable in `syntax-rules` pattern"

  defp format({:ellipsis_count_mismatch, name}) do
    "ellipsis substitution counts for pattern variable `#{name}` do not agree"
  end

  defp format({:ellipsis_no_pattern_var, where}) do
    "no pattern variable to drive ellipsis in #{where}"
  end

  defp format({:syntax_rules_arity, count}) do
    "`syntax-rules` requires a literals list and at least one rule (got #{count} forms)"
  end
end
