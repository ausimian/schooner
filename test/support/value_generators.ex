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

  @doc """
  Generator for any reader-readable Schooner value, depth-bounded.

  Excludes `:eof` and `:unspecified`, which have no Scheme source syntax
  and therefore cannot survive a `write`/`read` round-trip.
  """
  def readable_value(depth \\ 3) do
    one_of([
      readable_atom_value(),
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
      constant(true),
      constant(false),
      constant(:null),
      constant(:eof),
      constant(:unspecified)
    ])
  end

  def readable_atom_value do
    one_of([
      constant(true),
      constant(false),
      constant(:null)
    ])
  end

  def integer_value, do: integer()

  def float_value do
    # Bound to finite floats so equality semantics are well-defined.
    map(integer(-1_000_000..1_000_000), &(&1 / 1.0))
  end

  def char_value do
    # Unicode scalar values: 0..0xD7FF and 0xE000..0x10FFFF. Surrogates
    # (0xD800..0xDFFF) are not characters and would crash <<cp::utf8>>.
    one_of([integer(0..0xD7FF), integer(0xE000..0x10_FFFF)])
    |> map(&Value.char/1)
  end

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
    map(tuple({inner, inner}), fn {a, b} -> Value.pair(a, b) end)
  end
end
