defmodule Schooner.Primitives.Lazy do
  @moduledoc """
  Primitive substrate for the `(scheme lazy)` library.

  Schooner promises are tagged tuples `{:promise, thunk}` where
  `thunk` is a zero-arg procedure. `force` applies the thunk and, if
  the result is itself a promise, keeps unwrapping iteratively until
  it reaches a non-promise value.

  ## Memoisation

  r7rs allows promises to memoise their first force. Schooner has no
  mutation, so memoisation is **not** implemented — re-forcing a
  promise re-evaluates its thunk. This is a documented deviation. The
  iterative-tail-recursive idiom (the central use case for
  `delay-force` / streams) still terminates correctly because `force`
  loops on the inner result; what's lost is the constant-time
  re-force on already-forced promises.

  ## Surface

  This module exposes the host-side primitives:

    * `make-promise` — wrap a value as an already-forced promise.
    * `%lazy-from-thunk` — wrap a zero-arg procedure as a lazy
      promise. Used internally by the `delay` and `delay-force`
      macros (see `priv/scheme/lazy.scm`); the leading `%` keeps it
      out of polite company.
    * `force` — iteratively force a promise (or return the input as
      a value if it is not a promise).
    * `promise?` — predicate.
  """

  alias Schooner.Env
  alias Schooner.Eval
  alias Schooner.Value

  @doc "Define every `(scheme lazy)` primitive on `env`."
  @spec register_into(Env.t()) :: Env.t()
  def register_into(%Env{} = env) do
    Enum.reduce(specs(), env, fn {name, arity, fun}, acc ->
      Env.define(acc, name, Value.primitive(name, arity, fun))
    end)
  end

  @doc """
  Return every `(scheme lazy)` primitive as a `{name, arity, fun}`
  tuple. Used by both `register_into/1` and `Schooner.Library.Standard`.
  """
  @spec specs() :: [{binary(), 1, fun()}]
  def specs do
    [
      {"make-promise", 1, &make_promise/1},
      {"%lazy-from-thunk", 1, &lazy_from_thunk/1},
      {"force", 1, &force_/1},
      {"promise?", 1, &promise_p/1}
    ]
  end

  defp make_promise([value]), do: Value.promise(fn -> value end)
  defp lazy_from_thunk([thunk]), do: Value.promise(thunk)

  defp force_([value]), do: do_force(value)

  defp do_force({:promise, thunk}) when is_function(thunk, 0), do: do_force(thunk.())
  defp do_force({:promise, thunk}), do: do_force(Eval.apply_proc(thunk, []))
  defp do_force(other), do: other

  defp promise_p([v]), do: Value.bool(Value.promise?(v))
end
