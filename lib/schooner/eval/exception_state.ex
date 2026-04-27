defmodule Schooner.Eval.ExceptionState do
  @moduledoc """
  Per-process handler stack for Scheme `raise` / `raise-continuable` /
  `with-exception-handler` / `guard`.

  The stack is held in the process dictionary because Schooner's
  environment value is immutable: there's no way to thread a mutable
  handler list through `apply_proc`/`eval` without breaking the
  tail-call invariant. Each handler is a Schooner procedure value
  (closure or primitive) so `Eval.apply_proc/2` can invoke it
  uniformly.

  The stack is reset at the start of every top-level
  `Schooner.eval/2` call so that residue from a previous invocation
  in the same process — e.g. after a host-side test caught a
  `Schooner.Error` — does not influence subsequent runs.
  """

  @key {__MODULE__, :handlers}

  alias Schooner.Error, as: HostError
  alias Schooner.Eval
  alias Schooner.Value

  @doc "Reset the handler stack for a fresh top-level evaluation."
  @spec reset() :: :ok
  def reset do
    Process.delete(@key)
    :ok
  end

  @doc "Push `handler` (a Scheme procedure value) onto the stack."
  @spec push(Value.t()) :: :ok
  def push(handler) do
    Process.put(@key, [handler | get_stack()])
    :ok
  end

  @doc """
  Snapshot/restore the entire stack — every handler-installer
  (`with-exception-handler`, `guard`, the top-level embedding entry)
  saves the stack on entry and restores it on every exit path. A
  blind pop in the `after` clause would be wrong: `raise_value/1`
  itself pops handlers as it walks the chain, so by the time the
  `after` runs the just-installed handler may already be gone, and
  popping would discard an outer handler we didn't install.
  """
  @spec snapshot() :: [Value.t()]
  def snapshot, do: get_stack()

  @spec restore([Value.t()]) :: :ok
  def restore(stack) when is_list(stack) do
    Process.put(@key, stack)
    :ok
  end

  @doc """
  Raise `value`. Pops the topmost handler (so the handler runs in
  the *parent* dynamic extent — its own raises walk further up) and
  invokes it. If the handler returns normally the raise is
  non-continuable, so we re-raise a secondary error in the parent
  extent. With no handler installed, escapes to the host as
  `Schooner.Error`.
  """
  @spec raise_value(Value.t()) :: no_return()
  def raise_value(value) do
    case get_stack() do
      [] ->
        Kernel.raise(HostError, value: value)

      [handler | rest] ->
        Process.put(@key, rest)
        _ = Eval.apply_proc(handler, [value])
        raise_value(secondary_error(value))
    end
  end

  @doc """
  Raise `value` continuably. The handler runs in the parent dynamic
  extent; if it returns normally, that return value becomes the
  value of `(raise-continuable value)` and the original handler
  stack is restored so the call site sees the same dynamic extent
  it had before the raise. If the handler escapes (e.g. via a
  matching `guard` clause throwing) the popped handler is *not*
  re-installed — its dynamic extent is gone.
  """
  @spec raise_continuable(Value.t()) :: Value.t()
  def raise_continuable(value) do
    case get_stack() do
      [] ->
        Kernel.raise(HostError, value: value)

      [handler | rest] = stack ->
        Process.put(@key, rest)
        result = Eval.apply_proc(handler, [value])
        Process.put(@key, stack)
        result
    end
  end

  defp get_stack, do: Process.get(@key, [])

  defp secondary_error(original) do
    Value.error_object(
      :user,
      Value.string("exception handler returned from a non-continuable raise"),
      [original]
    )
  end
end
