defmodule Schooner.Primitives.Continuations do
  @moduledoc """
  Escape continuations and `dynamic-wind` from `(scheme base)`:
  `call/cc`, `call-with-current-continuation`, and `dynamic-wind`.

  ## Escape-only `call/cc`

  Schooner's continuations are *single-shot upward only*. `call/cc`
  reifies the current continuation as a Schooner procedure that, when
  invoked, escapes back to the original call site. The implementation
  mints a fresh `make_ref/0` tag at every `call/cc` entry, installs a
  `try ... catch` matching that tag, and registers the tag with
  `Schooner.Eval.ContinuationState` for the dynamic extent of the
  procedure call. Invoking the continuation throws
  `{:schooner_continuation, tag, value}`; the matching `catch` returns
  the value as the result of the original `call/cc`.

  Once the `call/cc` exits — by any path: matched escape, normal
  return, raised exception, or another continuation invocation that
  walks past us — its `after` clause deregisters the tag. A subsequent
  invocation of the now-stale continuation procedure observes the tag
  is gone and raises `Schooner.Eval.Error` with reason
  `:continuation_expired` rather than letting the throw propagate
  uncaught into Erlang. This is a documented deviation from r7rs
  (which mandates fully reusable continuations); lifting it to
  multi-shot full first-class `call/cc` is the planned v2.0 change
  per PLAN.md.

  ## `dynamic-wind` without an explicit wind stack

  Under escape-only continuations, every escape from inside a
  `dynamic-wind` body unwinds via `:erlang.throw/1` (the continuation
  procedure throws) or `Kernel.raise/1` (an exception escapes). Both
  fire the surrounding `try/after` clauses in innermost-first order
  as the stack unwinds, which is exactly the r7rs semantics for
  running `after` thunks on escape. A separate wind-stack data
  structure is therefore unnecessary at v1 — the `try/after`
  primitive fan-in already gives us the right ordering for free.

  v2.0's first-class `call/cc` does need an explicit wind stack
  (capturing a continuation must snapshot the wind frames so re-entry
  can re-fire `before` thunks). Until then, this module is just the
  binding layer over `try/after`.
  """

  alias Schooner.Eval
  alias Schooner.Eval.ContinuationState
  alias Schooner.Eval.Error
  alias Schooner.Primitive.Error, as: PrimError
  alias Schooner.Value

  @doc """
  Return every continuation primitive as a `{name, arity, fun}` tuple.
  Consumed by `Schooner.Library.Standard` as part of the
  `(scheme base)` assembly.
  """
  @spec specs() :: [{binary(), Value.arity_spec(), fun()}]
  def specs do
    [
      {"call-with-current-continuation", 1, &call_cc/1},
      {"call/cc", 1, &call_cc/1},
      {"dynamic-wind", 3, &dynamic_wind/1}
    ]
  end

  # ---------------------------------------------------------------------------
  # call/cc
  # ---------------------------------------------------------------------------

  defp call_cc([proc]) do
    require_procedure!("call/cc", proc)
    tag = make_ref()
    cont = make_continuation(tag)
    ContinuationState.register(tag)

    try do
      Eval.apply_proc(proc, [cont])
    catch
      :throw, {:schooner_continuation, ^tag, value} -> value
    after
      ContinuationState.deregister(tag)
    end
  end

  # The reified continuation procedure. When applied with one argument
  # it consults the live-tag registry: if the surrounding `call/cc` is
  # still on the stack, throw the matched tag; otherwise raise a
  # documented Schooner error rather than letting an unmatched throw
  # escape. Captured by reference so this file owns the throw-tag
  # vocabulary end-to-end.
  defp make_continuation(tag) do
    Value.primitive("continuation", 1, fn [value] ->
      if ContinuationState.live?(tag) do
        throw({:schooner_continuation, tag, value})
      else
        raise Error, reason: :continuation_expired
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # dynamic-wind
  # ---------------------------------------------------------------------------

  # `before` runs once on entry. `thunk` is the body whose value is
  # returned. `after` runs on every exit path: normal return,
  # exception, or escape via a continuation invocation. The `after`
  # thunk evaluates *outside* its own `dynamic-wind` extent — that's
  # what `try/after` gives us, and matches r7rs.
  defp dynamic_wind([before_thunk, thunk, after_thunk]) do
    require_procedure!("dynamic-wind", before_thunk)
    require_procedure!("dynamic-wind", thunk)
    require_procedure!("dynamic-wind", after_thunk)

    _ = Eval.apply_proc(before_thunk, [])

    try do
      Eval.apply_proc(thunk, [])
    after
      _ = Eval.apply_proc(after_thunk, [])
    end
  end

  defp require_procedure!(op, v) do
    if Value.procedure?(v) do
      :ok
    else
      raise PrimError, reason: {:type_error, op, "procedure", v}
    end
  end
end
