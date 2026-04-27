defmodule Schooner.Primitives.Write do
  @moduledoc """
  The `(scheme write)` library: `display`, `write`, `write-shared`,
  `write-simple`.

  Schooner has no port abstraction (see PLAN.md — I/O is delegated to
  host functions), so these primitives deviate from r7rs in two ways:

    1. They take exactly one argument — the value — with no port arg.
       The host wires up I/O explicitly via injected functions.
    2. They return the rendered text as a Scheme string instead of
       writing to a port and returning unspecified.

  This is the documented "string-port flavour" called out in the
  Phase 13 plan. `write-shared` and `write-simple` delegate to `write`
  because Schooner values are immutable persistent terms — there are
  no shared structures to label and no cycles to break.
  """

  alias Schooner.Env
  alias Schooner.Value

  @doc "Define every `(scheme write)` primitive on `env`."
  @spec register_into(Env.t()) :: Env.t()
  def register_into(%Env{} = env) do
    Enum.reduce(specs(), env, fn {name, arity, fun}, acc ->
      Env.define(acc, name, Value.primitive(name, arity, fun))
    end)
  end

  @doc """
  Return every `(scheme write)` primitive as a `{name, arity, fun}`
  tuple. Used by both `register_into/1` and `Schooner.Library.Standard`.
  """
  @spec specs() :: [{binary(), 1, fun()}]
  def specs do
    [
      {"write", 1, &write_/1},
      {"display", 1, &display_/1},
      {"write-shared", 1, &write_/1},
      {"write-simple", 1, &write_/1}
    ]
  end

  defp write_([value]), do: Value.string(Value.write(value))
  defp display_([value]), do: Value.string(Value.display(value))
end
