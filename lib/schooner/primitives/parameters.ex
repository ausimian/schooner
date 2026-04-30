defmodule Schooner.Primitives.Parameters do
  @moduledoc """
  Parameter-object primitives from `(scheme base)`: `make-parameter`
  and the runtime helper `%parameterize-apply` that the
  `parameterize` macro in `priv/scheme/base.scm` expands into.

  Dynamic-binding bookkeeping lives in
  `Schooner.Eval.ParameterState` — this module is the binding layer
  that exposes those operations to Scheme code. The `parameterize`
  derived form is a `syntax-rules` macro (so the binding expressions
  are evaluated by the regular evaluator and converters live as
  ordinary Scheme procedures), and only the runtime portion —
  collect bindings, push a frame, run the thunk, restore on every
  exit — is host-side.
  """

  alias Schooner.Eval
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Eval.ParameterState
  alias Schooner.Primitive.Error
  alias Schooner.Value

  @doc """
  Return every parameter primitive as a `{name, arity, fun}` tuple.
  Consumed by `Schooner.Library.Standard` as part of the
  `(scheme base)` assembly.
  """
  @spec specs() :: [{binary(), Value.arity_spec(), fun()}]
  def specs do
    [
      {"make-parameter", {:at_least, 1}, &make_parameter/1},
      {"%parameterize-apply", 2, &parameterize_apply/1}
    ]
  end

  # ---------------------------------------------------------------------------
  # make-parameter
  # ---------------------------------------------------------------------------

  defp make_parameter([init]), do: Value.parameter(init, nil)

  defp make_parameter([init, converter]) do
    require_procedure!("make-parameter", converter)
    Value.parameter(Eval.apply_proc(converter, [init]), converter)
  end

  defp make_parameter(args) do
    raise EvalError, reason: {:arity_mismatch, "make-parameter", {:at_most, 2}, length(args)}
  end

  # ---------------------------------------------------------------------------
  # %parameterize-apply
  # ---------------------------------------------------------------------------

  # `bindings` is a Scheme list of (parameter . value) pairs, built
  # by the `parameterize` macro from the source-order `(p v)`
  # clauses. Each value is run through the parameter's converter (if
  # any) *before* the frame is pushed, so a converter that errors
  # rolls back cleanly: the partially-built frame never reaches the
  # stack. The thunk is invoked for the dynamic extent of the frame.
  # snapshot/restore (rather than a blind pop in the `after`) matches
  # the established `with-exception-handler` pattern — a captured
  # escape continuation that fires *during* the thunk leaves the
  # stack at whatever depth it had when the escape walked through;
  # the outer `restore/1` then collapses everything back to the
  # pre-`parameterize` state.
  defp parameterize_apply([bindings, thunk]) do
    require_procedure!("parameterize", thunk)
    frame = build_frame(bindings, [])
    prev = ParameterState.snapshot()
    ParameterState.push_frame(frame)

    try do
      Eval.apply_proc(thunk, [])
    after
      ParameterState.restore(prev)
    end
  end

  defp build_frame([], acc), do: Enum.reverse(acc)

  defp build_frame([[{:parameter, id, _init, converter} | value] | rest], acc) do
    converted = if converter, do: Eval.apply_proc(converter, [value]), else: value
    build_frame(rest, [{id, converted} | acc])
  end

  defp build_frame([[non_param | _value] | _rest], _acc) do
    raise Error, reason: {:type_error, "parameterize", "parameter", non_param}
  end

  defp build_frame(other, _acc) do
    raise Error,
      reason: {:type_error, "parameterize", "list of (parameter . value) pairs", other}
  end

  defp require_procedure!(op, v) do
    if Value.procedure?(v) do
      :ok
    else
      raise Error, reason: {:type_error, op, "procedure", v}
    end
  end
end
