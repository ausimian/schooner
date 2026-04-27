defmodule Schooner.Expander.Error do
  @moduledoc """
  Exception raised by `Schooner.Expander` for malformed macro forms,
  failed pattern matches, and other expansion-time failures.
  """

  defexception [:reason, :message]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    %__MODULE__{reason: reason, message: format(reason)}
  end

  defp format({:bad_syntax, name}), do: "malformed `#{name}` form"

  defp format({:no_matching_rule, keyword}) do
    "no matching `syntax-rules` clause for `#{keyword}`"
  end

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

  defp format(:nested_define_syntax_unsupported) do
    "`define-syntax` is currently only supported at top level"
  end
end
