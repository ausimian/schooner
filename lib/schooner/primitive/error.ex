defmodule Schooner.Primitive.Error do
  @moduledoc """
  Exception raised by built-in primitives for domain-specific failures —
  type errors, division by zero, and the family of "would require rationals
  or complex" cases that Schooner explicitly does not implement.

  Kept distinct from `Schooner.Eval.Error` because primitives report a
  different vocabulary of failures than the evaluator. Tests can pattern
  on `:reason` to pin behaviour without coupling to wording.
  """

  defexception [:reason, :message]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    %__MODULE__{reason: reason, message: format(reason)}
  end

  defp format({:type_error, op, expected, got}) do
    "type error in `#{op}`: expected #{expected}, got #{inspect(got)}"
  end

  defp format({:division_by_zero, op}) do
    "division by zero in `#{op}`"
  end

  defp format({:exact_division_not_integer, num, den}) do
    "exact division `(/ #{num} #{den})` would yield a rational; Schooner has no rational tower"
  end

  defp format({:negative_exponent, base, exp}) do
    "`(expt #{inspect(base)} #{inspect(exp)})` would yield a rational; Schooner has no rational tower"
  end

  defp format({:irrational, op, arg}) do
    "`(#{op} #{inspect(arg)})` would yield an irrational; Schooner has no rational tower"
  end

  defp format({:not_representable_exact, value}) do
    "`#{inspect(value)}` is not representable as an exact integer"
  end
end
