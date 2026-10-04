defmodule Schooner.Location do
  @moduledoc """
  A position in Scheme source: the file it came from, if known, and
  the 1-based `line` and `column` of the first character of the form.

  Every script-level exception carries a `:location` field holding one
  of these, or `nil` when no position is known. When the location names
  a file, the exception's message is prefixed with `file:line:col: `.
  Pass `:file` to `Schooner.eval/3` or `Schooner.compile/3` to supply
  it. Use `Schooner.format_error/2` to render an error for people.
  """

  @enforce_keys [:line, :column]
  defstruct [:file, :line, :column]

  @type t :: %__MODULE__{file: binary() | nil, line: pos_integer(), column: pos_integer()}

  @doc false
  @spec new(binary() | nil, {pos_integer(), pos_integer()} | nil) :: t() | nil
  def new(_file, nil), do: nil
  def new(file, {line, column}), do: %__MODULE__{file: file, line: line, column: column}

  @doc false
  # The prefix added to an exception message: `file:line:col: ` when
  # the location names a file, and nothing otherwise.
  @spec prefix(t() | nil) :: binary()
  def prefix(%__MODULE__{file: file} = loc) when is_binary(file), do: to_string(loc) <> ": "
  def prefix(_), do: ""

  @doc false
  # Give `exception` the location `loc` unless it already has one, so
  # the innermost location to reach an error is the one it keeps.
  # Exceptions without a `:location` field pass through unchanged.
  @spec attach(Exception.t(), t() | nil) :: Exception.t()
  def attach(%{location: nil, __struct__: mod} = exception, %__MODULE__{} = loc) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :put_location, 2) do
      mod.put_location(exception, loc)
    else
      %{exception | location: loc, message: prefix(loc) <> exception.message}
    end
  end

  def attach(exception, _loc), do: exception

  @doc false
  # Name `file` in a location recorded before the file was known: the
  # reader, expander and import resolution do not see the file name, so
  # the entry point that does fills it in.
  @spec put_file(Exception.t(), binary() | nil) :: Exception.t()
  def put_file(%{location: %__MODULE__{file: nil} = loc} = exception, file)
      when is_binary(file),
      do: attach(%{exception | location: nil}, %{loc | file: file})

  def put_file(exception, _file), do: exception

  defimpl String.Chars do
    def to_string(%{file: nil, line: line, column: column}), do: "#{line}:#{column}"
    def to_string(%{file: file, line: line, column: column}), do: "#{file}:#{line}:#{column}"
  end
end
