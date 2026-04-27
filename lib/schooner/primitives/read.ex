defmodule Schooner.Primitives.Read do
  @moduledoc """
  The `(scheme read)` library: a single `read` procedure.

  Schooner has no port abstraction (see PLAN.md), so this is the
  string-port flavour called out in the Phase 13 plan: `read` takes
  exactly one argument — a Scheme string — and returns the first
  datum parsed from it. An empty string returns `eof`.

  This is a documented deviation from r7rs, which makes `read` take a
  port and read incrementally. A future phase that introduces ports
  (or, more likely, a host-injected reader function) can replace this
  surface.
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

  defp read_([{:string, source}]) do
    case Reader.read_string(source) do
      [] -> :eof
      [first | _rest] -> first
    end
  end

  defp read_([other]) do
    raise Schooner.Primitive.Error, reason: {:type_error, "read", "string", other}
  end
end
