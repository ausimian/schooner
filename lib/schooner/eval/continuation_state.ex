defmodule Schooner.Eval.ContinuationState do
  @moduledoc """
  Per-process registry of currently-live escape-continuation tags.

  When `call/cc` is entered it mints a fresh `make_ref/0` tag, installs
  a `try ... catch :throw, {:schooner_continuation, ^tag, value}` around
  the call to the user procedure, and registers the tag here. The
  reified continuation value is a Schooner primitive that, when applied,
  consults this registry: if the tag is still live the primitive throws
  `{:schooner_continuation, tag, value}` and the matching `catch`
  returns; if the tag is gone the primitive raises
  `Schooner.Eval.Error` with reason `:continuation_expired`.

  This is what makes Schooner's continuations *escape-only* in a
  user-observable way — invoking a captured continuation after its
  dynamic extent has ended is a documented error rather than undefined
  behaviour. See PLAN.md phase 12 and the v2.0 follow-up note: lifting
  this restriction (multi-shot, full re-entry) is non-breaking for
  scripts that respect the v1 contract because it removes an error case
  rather than adding one.

  The set is reset by `Schooner.eval/2` at the start of every top-level
  call, mirroring `Schooner.Eval.ExceptionState`.
  """

  @key {__MODULE__, :live}

  @doc "Reset the live-tag set for a fresh top-level evaluation."
  @spec reset() :: :ok
  def reset do
    Process.delete(@key)
    :ok
  end

  @doc "Snapshot the live-tag set; used by re-entrant top-level evals."
  @spec snapshot() :: MapSet.t(reference())
  def snapshot, do: get_set()

  @spec restore(MapSet.t(reference())) :: :ok
  def restore(set) do
    if MapSet.size(set) == 0 do
      Process.delete(@key)
    else
      Process.put(@key, set)
    end

    :ok
  end

  @doc "Mark `tag` as live for the duration of an active `call/cc` extent."
  @spec register(reference()) :: :ok
  def register(tag) when is_reference(tag) do
    Process.put(@key, MapSet.put(get_set(), tag))
    :ok
  end

  @doc "Mark `tag` as gone — the surrounding `call/cc` has exited."
  @spec deregister(reference()) :: :ok
  def deregister(tag) when is_reference(tag) do
    new_set = MapSet.delete(get_set(), tag)

    if MapSet.size(new_set) == 0 do
      Process.delete(@key)
    else
      Process.put(@key, new_set)
    end

    :ok
  end

  @doc "Is `tag` currently inside an active `call/cc` extent?"
  @spec live?(reference()) :: boolean()
  def live?(tag) when is_reference(tag), do: MapSet.member?(get_set(), tag)

  defp get_set, do: Process.get(@key, MapSet.new())
end
