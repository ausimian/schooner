defmodule Schooner.Primitives.Read do
  @moduledoc """
  The `(scheme read)` library: a single `read` procedure.

  Schooner has no port abstraction (see PLAN.md), so `read` takes
  exactly one argument, a Scheme string, and returns the first datum
  parsed from it. A string containing no datum returns `eof`.

  This is a documented deviation from r7rs, where `read` takes a port
  and reads incrementally.
  """

  alias Schooner.Reader

  @doc """
  Return every `(scheme read)` primitive as a `{name, arity, fun}`
  tuple. Used by `Schooner.Library.Standard` to assemble
  `(scheme read)`.
  """
  @spec specs() :: [{binary(), 1, fun()}]
  def specs do
    [
      {"read", 1, &read_/1}
    ]
  end

  defp read_([source]) when is_binary(source) do
    case Reader.read_string(source) do
      [] -> :eof
      [first | _rest] -> first
    end
  end

  defp read_([other]) do
    raise Schooner.Primitive.Error, reason: {:type_error, "read", "string", other}
  end
end
