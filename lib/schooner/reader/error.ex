defmodule Schooner.Reader.Error do
  @moduledoc """
  Exception raised by the reader on malformed source.

  Each error carries:

    * `:reason` — a structured term identifying the failure mode (atom or
      tagged tuple); meant to be machine-matchable in tests
    * `:position` — `{line, column}` of the offending input
    * `:location` — the same position as a `Schooner.Location`, naming
      the file when the caller supplied one

  `:message` is derived from `:reason` and `:position`, so tests can
  assert on those fields without coupling to the wording. When the
  location names a file, the message is `file:line:col: ` followed by
  the description instead.
  """

  alias Schooner.Location

  defexception [:reason, :position, :message, :location]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    position = Keyword.fetch!(opts, :position)
    location = Keyword.get(opts, :location, Location.new(nil, position))

    %__MODULE__{
      reason: reason,
      position: position,
      location: location,
      message: format(reason, location)
    }
  end

  @doc false
  def put_location(%__MODULE__{reason: reason, position: position}, %Location{file: file}),
    do: exception(reason: reason, position: position, location: Location.new(file, position))

  defp format(reason, %Location{file: file} = location) when is_binary(file),
    do: Location.prefix(location) <> describe(reason)

  defp format(reason, %Location{line: line, column: col}),
    do: "#{describe(reason)} at line #{line}, column #{col}"

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
