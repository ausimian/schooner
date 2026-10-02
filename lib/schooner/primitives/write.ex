defmodule Schooner.Primitives.Write do
  @moduledoc """
  The `(scheme write)` library — `display`, `write`, `write-shared`,
  `write-simple` — plus the `(scheme base)` output primitives
  `newline` and `write-string`.

  Schooner has no port abstraction (see PLAN.md — I/O is delegated to
  host functions), so these primitives deviate from r7rs in two ways:

    1. They take only the value, with no port argument. Hosts that
       need output inject their own functions.
    2. They return the rendered text as a Scheme string instead of
       writing to a port and returning unspecified. `(newline)`
       returns `"\\n"`; `(write-string str)` returns `str` unchanged.

  `write-shared` and `write-simple` delegate to `write`. Schooner
  values are immutable, so they cannot contain cycles, and shared
  substructure is written out in full rather than labelled.
  """

  alias Schooner.Primitive.Error
  alias Schooner.Value

  @doc """
  Return every `(scheme write)` primitive as a `{name, arity, fun}`
  tuple. Used by `Schooner.Library.Standard` to assemble
  `(scheme write)`.
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

  @doc """
  Return the `(scheme base)` output primitives shipped here:
  `newline` and `write-string`. Kept separate from `specs/0` so the
  `(scheme write)` library entry stays purely r7rs `(scheme write)`.
  """
  @spec base_io_specs() :: [{binary(), non_neg_integer(), fun()}]
  def base_io_specs do
    [
      {"newline", 0, &newline_/1},
      {"write-string", 1, &write_string/1}
    ]
  end

  defp write_([value]), do: Value.string(Value.write(value))
  defp display_([value]), do: Value.string(Value.display(value))

  defp newline_([]), do: Value.string("\n")

  defp write_string([s]) when is_binary(s), do: s

  defp write_string([other]),
    do: raise(Error, reason: {:type_error, "write-string", "string", other})
end
