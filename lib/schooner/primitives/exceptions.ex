defmodule Schooner.Primitives.Exceptions do
  @moduledoc """
  Exception-system primitives from `(scheme base)`: `error`,
  `raise`, `raise-continuable`, `with-exception-handler`, and the
  predicate / accessor family for error objects (`error?`,
  `error-object?`, `read-error?`, `file-error?`,
  `error-object-message`, `error-object-irritants`).

  Handler bookkeeping lives in `Schooner.Eval.ExceptionState` —
  this module is the binding layer that exposes those operations
  to Scheme code. The `guard` derived form is implemented as a
  core form in `Schooner.Eval` because it needs to escape the
  body via `throw`/`catch` once a clause matches; the throw tag
  is internal so it cannot be observed from Scheme.
  """

  alias Schooner.Eval
  alias Schooner.Eval.ExceptionState
  alias Schooner.Primitive.Error
  alias Schooner.Value

  @doc """
  Return every exception primitive as a `{name, arity, fun}` tuple.
  Consumed by `Schooner.Library.Standard` as part of the
  `(scheme base)` assembly.
  """
  @spec specs() :: [{binary(), non_neg_integer() | {:at_least, non_neg_integer()}, fun()}]
  def specs do
    [
      {"error", {:at_least, 1}, &error/1},
      {"error?", 1, &error_p/1},
      {"error-object?", 1, &error_p/1},
      {"read-error?", 1, &read_error_p/1},
      {"file-error?", 1, &file_error_p/1},
      {"error-object-message", 1, &error_message/1},
      {"error-object-irritants", 1, &error_irritants/1},
      {"raise", 1, &raise_/1},
      {"raise-continuable", 1, &raise_continuable/1},
      {"with-exception-handler", 2, &with_exception_handler/1}
    ]
  end

  # ---------------------------------------------------------------------------
  # error — construct an error object and raise it (non-continuable)
  # ---------------------------------------------------------------------------

  defp error([{:string, _} = msg | irritants]) do
    obj = Value.error_object(:user, msg, irritants)
    ExceptionState.raise_value(obj)
  end

  defp error([other | _]) do
    raise Error, reason: {:type_error, "error", "string", other}
  end

  # ---------------------------------------------------------------------------
  # Predicates
  # ---------------------------------------------------------------------------

  defp error_p([v]), do: Value.bool(Value.error_object?(v))
  defp read_error_p([v]), do: Value.bool(Value.error_kind?(v, :read))
  defp file_error_p([v]), do: Value.bool(Value.error_kind?(v, :file))

  # ---------------------------------------------------------------------------
  # Accessors
  # ---------------------------------------------------------------------------

  defp error_message([{:error_obj, _kind, message, _}]), do: message

  defp error_message([other]) do
    raise Error, reason: {:type_error, "error-object-message", "error object", other}
  end

  defp error_irritants([{:error_obj, _kind, _msg, irritants}]), do: Value.list(irritants)

  defp error_irritants([other]) do
    raise Error, reason: {:type_error, "error-object-irritants", "error object", other}
  end

  # ---------------------------------------------------------------------------
  # raise / raise-continuable
  # ---------------------------------------------------------------------------

  defp raise_([value]), do: ExceptionState.raise_value(value)

  defp raise_continuable([value]), do: ExceptionState.raise_continuable(value)

  # ---------------------------------------------------------------------------
  # with-exception-handler
  # ---------------------------------------------------------------------------

  # Both args must be procedures. Handler is pushed for the dynamic
  # extent of the thunk's invocation; on every exit path the handler
  # stack is restored to its state from before the call. We can't
  # just `pop` once in the `after` clause because `raise_value`
  # itself pops handlers as it walks the chain — so by the time the
  # `after` runs, the handler we pushed may already be gone, and a
  # blind pop would discard a handler installed *outside* this
  # call. The snapshot/restore pattern collapses every escape path
  # to the same observable: the stack on exit equals the stack on
  # entry. The thunk call itself is *not* in tail position with
  # respect to the surrounding code — that's an unavoidable cost of
  # dynamic-extent handler installation, and is fixed at one BEAM
  # stack frame per handler boundary regardless of how deep the body
  # recurses (TCO inside the body still flattens tail self-calls).
  defp with_exception_handler([handler, thunk]) do
    require_procedure!("with-exception-handler", handler)
    require_procedure!("with-exception-handler", thunk)
    prev = ExceptionState.snapshot()
    ExceptionState.push(handler)

    try do
      Eval.apply_proc(thunk, [])
    after
      ExceptionState.restore(prev)
    end
  end

  defp require_procedure!(op, v) do
    if Value.procedure?(v) do
      :ok
    else
      raise Error, reason: {:type_error, op, "procedure", v}
    end
  end
end
