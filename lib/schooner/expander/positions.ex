defmodule Schooner.Expander.Positions do
  @moduledoc false

  # Helpers for walking a `Schooner.Reader` position tree alongside its
  # datum during expansion and analysis. Every helper accepts `nil` for
  # a form with no known position and returns `nil` for its parts, so
  # code that never had positions pays almost nothing for carrying them.

  alias Schooner.Lexer
  alias Schooner.Reader

  @type t :: Reader.pos_tree() | nil

  @doc "The `{line, column}` the tree starts at, or `nil`."
  @spec at(t()) :: Lexer.position() | nil
  def at({:pair, pos, _, _}), do: pos
  def at({:atom, pos}), do: pos
  def at({:vector, pos, _}), do: pos
  def at({:bytevector, pos}), do: pos
  def at(nil), do: nil

  @doc "The tree for the car of a pair."
  @spec car(t()) :: t()
  def car({:pair, _, car, _}), do: car
  def car(_), do: nil

  @doc "The tree for the cdr of a pair."
  @spec cdr(t()) :: t()
  def cdr({:pair, _, _, cdr}), do: cdr
  def cdr(_), do: nil

  @doc "The trees of the first `n` cdrs' cars: the elements of a list."
  @spec nth(t(), non_neg_integer()) :: t()
  def nth(tree, 0), do: car(tree)
  def nth(tree, n), do: nth(cdr(tree), n - 1)

  @doc "The tree after dropping `n` pairs from a list."
  @spec drop(t(), non_neg_integer()) :: t()
  def drop(tree, 0), do: tree
  def drop(tree, n), do: drop(cdr(tree), n - 1)

  @doc """
  Build the tree of a list whose element trees are `items`, ending in
  `tail` (`nil` for a proper list), with every spine pair placed at
  `tree`'s position.
  """
  @spec list([t()], t(), t()) :: t()
  def list(_items, _tail, nil), do: nil

  def list(items, tail, tree) do
    pos = at(tree)
    do_list(items, tail || {:atom, pos}, pos)
  end

  defp do_list([], tail, _pos), do: tail
  defp do_list([h | t], tail, pos), do: {:pair, pos, h, do_list(t, tail, pos)}

  @doc """
  The tree of a pair built from `car` and `cdr` trees at `tree`'s
  position.
  """
  @spec cons(t(), t(), t()) :: t()
  def cons(_car, _cdr, nil), do: nil
  def cons(car, cdr, tree), do: {:pair, at(tree), car, cdr}

  @doc """
  A tree for `form` with every node placed at `tree`'s position, for
  forms the expander builds itself.
  """
  @spec fresh(term(), t()) :: t()
  def fresh(_form, nil), do: nil
  def fresh(form, tree), do: do_fresh(form, at(tree))

  defp do_fresh([h | t], pos), do: {:pair, pos, do_fresh(h, pos), do_fresh(t, pos)}

  defp do_fresh({:vector, items}, pos),
    do: {:vector, pos, items |> Tuple.to_list() |> Enum.map(&do_fresh(&1, pos))}

  defp do_fresh(_atom, pos), do: {:atom, pos}
end
