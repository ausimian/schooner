defmodule Schooner.Primitives.Cxr do
  @moduledoc """
  The `(scheme cxr)` library: every `c…r` accessor of depth 2, 3, and 4
  composed from `car` and `cdr`.

  Each spelling like `caddr` reads right-to-left as a chain of pair
  walks: `(caddr x)` ≡ `(car (cdr (cdr x)))`. We enumerate the 28 names
  via a list comprehension rather than hand-writing each definition,
  which keeps the mapping unambiguous and the code under a hundred lines.
  """

  alias Schooner.Env
  alias Schooner.Primitive.Error
  alias Schooner.Value

  # Names of length 2/3/4 between `c` and `r`, in the canonical r7rs order
  # (depth-first over `a`/`d` per position, outermost first).
  @names for n <- 2..4,
             chars <-
               (case n do
                  2 ->
                    for(a <- ["a", "d"], b <- ["a", "d"], do: [a, b])

                  3 ->
                    for(
                      a <- ["a", "d"],
                      b <- ["a", "d"],
                      c <- ["a", "d"],
                      do: [a, b, c]
                    )

                  4 ->
                    for(
                      a <- ["a", "d"],
                      b <- ["a", "d"],
                      c <- ["a", "d"],
                      d <- ["a", "d"],
                      do: [a, b, c, d]
                    )
                end),
             do: "c" <> Enum.join(chars) <> "r"

  @doc "Register every `c..r` accessor on `env`."
  @spec register_into(Env.t()) :: Env.t()
  def register_into(%Env{} = env) do
    Enum.reduce(@names, env, fn name, acc ->
      Env.define(acc, name, Value.primitive(name, 1, build_fun(name)))
    end)
  end

  # Letters between `c` and `r` apply right-to-left: `(caddr x)` ⇒ d, d, a.
  defp build_fun(name) do
    ops = name |> String.slice(1..-2//1) |> String.graphemes() |> Enum.reverse()
    fn [v] -> apply_chain(name, ops, v) end
  end

  defp apply_chain(_name, [], v), do: v
  defp apply_chain(name, ["a" | rest], {:pair, a, _}), do: apply_chain(name, rest, a)
  defp apply_chain(name, ["d" | rest], {:pair, _, d}), do: apply_chain(name, rest, d)

  defp apply_chain(name, _ops, other),
    do: raise(Error, reason: {:type_error, name, "pair", other})
end
