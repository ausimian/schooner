defmodule Schooner.Primitives.Compare do
  @moduledoc """
  Shared variadic-pairwise comparison loop used by the numeric, string,
  and char comparator families.

  Callers handle type-checking up front (each domain has its own type
  predicate) and supply a `pair` callback plus a `key` projection. The
  loop walks the list applying `pair.(key.(a), key.(b))` to each
  adjacent pair until one fails or the list is exhausted.
  """

  @doc """
  Walk `list` pairwise, returning `true` iff `pair.(key.(a), key.(b))`
  holds for every adjacent pair `(a, b)`. A single-element list is
  vacuously true; the input is assumed non-empty.
  """
  @spec variadic_pairwise([term()], (term(), term() -> boolean()), (term() -> term())) ::
          boolean()
  def variadic_pairwise([_], _pair, _key), do: true

  def variadic_pairwise([a, b | rest], pair, key) do
    if pair.(key.(a), key.(b)),
      do: variadic_pairwise([b | rest], pair, key),
      else: false
  end
end
