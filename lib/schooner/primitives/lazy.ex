defmodule Schooner.Primitives.Lazy do
  @moduledoc """
  Primitive substrate for the `(scheme lazy)` library.

  A promise is either `{:promise, :lazy, thunk}`, where `thunk` is a
  zero-argument procedure, or `{:promise, :forced, value}`. `force`
  applies a lazy promise's thunk and, if the result is itself a
  promise, keeps forcing iteratively until it reaches a non-promise
  value.

  ## Memoisation

  r7rs requires a promise to remember the value of its first force.
  Schooner has no mutation, so memoisation is **not** implemented:
  re-forcing a lazy promise re-evaluates its thunk. This is a
  documented deviation. Iterative lazy algorithms built on
  `delay-force` (the main use case for streams) still run in constant
  stack space because `force` loops on the inner result; what is lost
  is constant-time re-forcing of an already-forced promise.

  ## Surface

  This module provides the primitives:

    * `make-promise` — wrap a value as an already-forced promise.
    * `%lazy-from-thunk` — wrap a zero-arg procedure as a lazy
      promise. Used internally by the `delay` and `delay-force`
      macros (see `priv/scheme/lazy.scm`); the leading `%` marks it
      as internal.
    * `force` — iteratively force a promise (or return the input as
      a value if it is not a promise).
    * `promise?` — predicate.
  """

  alias Schooner.Eval
  alias Schooner.Value

  @doc """
  Return every `(scheme lazy)` primitive as a `{name, arity, fun}`
  tuple. Used by `Schooner.Library.Standard` to assemble
  `(scheme lazy)`.
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

  defp make_promise([value]), do: Value.eager_promise(value)
  defp lazy_from_thunk([thunk]), do: Value.lazy_promise(thunk)

  defp force_([value]), do: do_force(value)

  # Keep forcing while the result is a promise: r7rs §4.2.5 requires
  # `force` on a promise whose value is itself a promise to force that
  # one too.
  defp do_force({:promise, :forced, value}), do: do_force(value)
  defp do_force({:promise, :lazy, thunk}), do: do_force(Eval.apply_proc(thunk, []))
  defp do_force(other), do: other

  defp promise_p([v]), do: Value.bool(Value.promise?(v))
end
