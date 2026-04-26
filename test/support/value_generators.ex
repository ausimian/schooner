defmodule Schooner.Test.ValueGenerators do
  @moduledoc """
  StreamData generators for `Schooner.Value` terms.

  Closures and primitives are deliberately excluded — they wrap functions
  whose identity is observable but content isn't, which makes them poor
  fits for property tests built around structural equality and round-trip
  rendering.
  """

  import StreamData

  alias Schooner.Value

  @doc "Generator for any non-procedure Schooner value, depth-bounded."
  def value(depth \\ 3) do
    one_of([
      atom_value(),
      integer_value(),
      float_value(),
      char_value(),
      string_value(),
      bytevector_value(),
      symbol_value()
    ])
    |> compound_value(depth)
  end

  defp compound_value(leaf, 0), do: leaf

  defp compound_value(leaf, depth) do
    one_of([
      leaf,
      list_value(leaf, depth - 1),
      vector_value(leaf, depth - 1),
      pair_value(leaf, depth - 1)
    ])
  end

  def atom_value do
    one_of([
      constant({:bool, true}),
      constant({:bool, false}),
      constant(:null),
      constant(:eof),
      constant(:unspecified)
    ])
  end

  def integer_value, do: integer()

  def float_value do
    # Bound to finite floats so equality semantics are well-defined.
    map(integer(-1_000_000..1_000_000), &(&1 / 1.0))
  end

  def char_value, do: map(integer(0..0x10_FFFF), &Value.char/1)

  def string_value do
    string(:utf8, max_length: 16)
    |> map(&Value.string/1)
  end

  def bytevector_value do
    binary(max_length: 16)
    |> map(&Value.bytevector/1)
  end

  def symbol_value do
    string(:alphanumeric, min_length: 1, max_length: 12)
    |> filter(fn s -> not String.match?(s, ~r/^\d/) end)
    |> map(&Value.symbol/1)
  end

  def list_value(leaf, depth) do
    leaf
    |> compound_value(depth)
    |> list_of(max_length: 6)
    |> map(&Value.list/1)
  end

  def vector_value(leaf, depth) do
    leaf
    |> compound_value(depth)
    |> list_of(max_length: 6)
    |> map(&Value.vector/1)
  end

  def pair_value(leaf, depth) do
    inner = compound_value(leaf, depth)
    map({inner, inner}, fn {a, b} -> Value.pair(a, b) end)
  end
end
