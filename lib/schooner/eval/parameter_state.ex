defmodule Schooner.Eval.ParameterState do
  @moduledoc """
  Per-process dynamic-binding stack for Scheme `make-parameter` /
  `parameterize`.

  A parameter object is a procedure value that, when called with no
  arguments, returns its current value. `parameterize` shadows that
  current value for the dynamic extent of its body. The stack lives in
  the process dictionary for the same reason as
  `Schooner.Eval.ExceptionState`'s handler stack: Schooner's
  environment value is immutable, so threading a mutable parameter map
  through `apply_proc`/`eval` would break the tail-call invariant.

  Each frame is a list of `{id, value}` pairs (one frame per
  `parameterize` form, holding *all* of its bindings). `lookup/2`
  walks frames most-recent-first and within a frame left-to-right, so
  an inner `parameterize` shadows an outer one and the source order
  of bindings within a single `parameterize` is preserved on
  same-parameter clashes (left-most wins).

  The stack is reset at the start of every top-level `Schooner.eval/2`
  call so residue from a previous invocation in the same process —
  e.g. after a host-side test caught a `Schooner.Error` — does not
  influence subsequent runs.
  """

  @key {__MODULE__, :stack}

  @type id :: integer()
  @type frame :: [{id(), term()}]

  @doc "Reset the parameter stack for a fresh top-level evaluation."
  @spec reset() :: :ok
  def reset do
    Process.delete(@key)
    :ok
  end

  @doc """
  Snapshot/restore the entire stack. Every `parameterize`-installer
  saves the stack on entry and restores it on every exit path. The
  symmetric pattern is identical to `ExceptionState`'s — see its
  module docs for why a blind pop in an `after` clause is wrong.
  """
  @spec snapshot() :: [frame()]
  def snapshot, do: get_stack()

  @spec restore([frame()]) :: :ok
  def restore([]) do
    Process.delete(@key)
    :ok
  end

  def restore(stack) when is_list(stack) do
    Process.put(@key, stack)
    :ok
  end

  @doc "Push `frame` (the bindings of one `parameterize` form) onto the stack."
  @spec push_frame(frame()) :: :ok
  def push_frame(frame) when is_list(frame) do
    Process.put(@key, [frame | get_stack()])
    :ok
  end

  @doc """
  Look up `id` in the stack, walking frames newest-first. Returns
  `default` if no `parameterize` is currently shadowing the
  parameter — that's the parameter's converted initial value, set
  by `make-parameter`.
  """
  @spec lookup(id(), term()) :: term()
  def lookup(id, default) do
    walk(get_stack(), id, default)
  end

  defp walk([], _id, default), do: default

  defp walk([frame | rest], id, default) do
    case List.keyfind(frame, id, 0) do
      {^id, value} -> value
      nil -> walk(rest, id, default)
    end
  end

  defp get_stack, do: Process.get(@key, [])
end
