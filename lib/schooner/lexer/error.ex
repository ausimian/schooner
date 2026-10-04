defmodule Schooner.Lexer.Error do
  @moduledoc """
  Exception raised by the lexer on malformed source.

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

  defp describe(:unterminated_string), do: "unterminated string literal"
  defp describe(:unterminated_block_comment), do: "unterminated block comment"
  defp describe(:unterminated_bar_identifier), do: "unterminated |identifier|"
  defp describe(:unterminated_char_literal), do: "unterminated character literal"
  defp describe(:unterminated_hex_escape), do: "unterminated hex escape"
  defp describe(:empty_hex_escape), do: "empty hex escape `\\x;`"
  defp describe(:invalid_numeric_literal), do: "invalid numeric literal"
  defp describe(:empty_atom), do: "empty token"
  defp describe({:invalid_numeric_literal, raw}), do: "invalid numeric literal #{inspect(raw)}"
  defp describe({:invalid_token, raw}), do: "invalid token #{inspect(raw)}"
  defp describe({:invalid_identifier, raw}), do: "invalid identifier #{inspect(raw)}"
  defp describe({:invalid_hash_form, c}), do: "invalid `#` form `#{<<c>>}`"

  defp describe({:invalid_boolean, c}),
    do: "invalid character after boolean literal: #{inspect(<<c>>)}"

  defp describe({:invalid_escape, c}), do: "invalid string escape `\\#{<<c>>}`"
  defp describe({:unknown_char_name, name}), do: "unknown character name `#\\#{name}`"

  defp describe({:duplicate_number_prefix, kind}),
    do: "duplicate #{kind} prefix in numeric literal"

  defp describe({:unexpected_char, c}), do: "unexpected character #{inspect(<<c>>)}"
end
