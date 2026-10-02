defmodule Schooner.Primitives.Parameters do
  @moduledoc """
  Parameter-object primitives from `(scheme base)`: `make-parameter`
  and the runtime helper `%parameterize-apply` that the
  `parameterize` macro in `priv/scheme/base.scm` expands into.

  Dynamic-binding bookkeeping lives in `Schooner.Eval.ParameterState`;
  this module exposes those operations to Scheme code. `parameterize`
  is a `syntax-rules` macro, so the parameter and value expressions
  are evaluated by the regular evaluator and converters are ordinary
  Scheme procedures. Only the runtime portion is implemented in
  Elixir: collect the bindings, push a frame, run the thunk, and
  restore the stack on every exit.
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
  # by the `parameterize` macro from the `(p v)` clauses in source
  # order. Each value is run through the parameter's converter (if
  # any) *before* the frame is pushed, so if a converter raises, the
  # partially built frame never reaches the stack. The thunk runs for
  # the dynamic extent of the frame. As in `with-exception-handler`,
  # the stack is restored from a snapshot rather than popped in the
  # `after`: an escape continuation invoked during the thunk can leave
  # the stack at any depth, and `restore/1` returns it to its
  # pre-`parameterize` state regardless.
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
