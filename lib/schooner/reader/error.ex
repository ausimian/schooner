defmodule Schooner.Reader.Error do
  @moduledoc """
  Exception raised by the reader on malformed source.

  Each error carries:

    * `:reason` — a structured term identifying the failure mode (atom or
      tagged tuple); meant to be machine-matchable in tests
    * `:position` — `{line, column}` of the offending input

  The pretty `:message` is generated lazily so tests can assert on
  `:reason` and `:position` without coupling to wording.
  """

  defexception [:reason, :position, :message]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    position = Keyword.fetch!(opts, :position)
    %__MODULE__{reason: reason, position: position, message: format(reason, position)}
  end

  defp format(reason, {line, col}) do
    "#{describe(reason)} at line #{line}, column #{col}"
  end

  defp describe(:unterminated_list), do: "unterminated list"
  defp describe(:unterminated_vector), do: "unterminated vector"
  defp describe(:unterminated_bytevector), do: "unterminated bytevector"
  defp describe(:unexpected_close_paren), do: "unexpected `)`"
  defp describe(:unexpected_dot), do: "unexpected `.` outside list context"
  defp describe(:dot_at_list_start), do: "`.` must follow at least one datum in a list"
  defp describe(:dot_in_vector), do: "`.` is not allowed in a vector literal"
  defp describe(:missing_tail_after_dot), do: "missing tail datum after `.`"
  defp describe(:extra_after_dot), do: "more than one datum after `.` in a list"
  defp describe(:datum_comment_at_eof), do: "datum comment `#;` with no following datum"
  defp describe({:invalid_byte, n}), do: "invalid byte in bytevector: #{inspect(n)}"

  defp describe({:invalid_in_bytevector, tag}),
    do: "non-byte token #{inspect(tag)} in bytevector"

  defp describe({:unexpected_eof_after, name}),
    do: "unexpected end of input after `#{name}`"
end
