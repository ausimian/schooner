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

  defp format({:index_out_of_range, op, index, length}) do
    "index #{index} out of range in `#{op}` (length #{length})"
  end

  defp format({:improper_list, op, value}) do
    "`#{op}` requires a proper list, got #{inspect(value)}"
  end

  defp format({:length_mismatch, op}) do
    "`#{op}` requires arguments of equal length"
  end

  defp format({:invalid_utf8, op}) do
    "`#{op}` received bytes that are not valid UTF-8"
  end

  defp format({:codepoint_out_of_range, op, cp}) do
    "`#{op}`: #{inspect(cp)} is not a Unicode scalar value"
  end

  defp format({:byte_out_of_range, op, b}) do
    "`#{op}`: #{inspect(b)} is not a byte (0..255)"
  end

  defp format({:invalid_size, op, k}) do
    "`#{op}`: #{inspect(k)} is not a valid size"
  end

  defp format({:wrong_record_type, op, type_name}) do
    "`#{op}`: value is not a record of type `#{type_name}`"
  end
end
