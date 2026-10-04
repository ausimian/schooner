defmodule Schooner.Eval.BacktraceState do
  @moduledoc """
  Per-process history of recent procedure applications, kept while a
  script runs with `debug: true`.

  Proper tail calls leave no Scheme call stack to inspect after an
  error, so code compiled with `debug: true` records each application
  it makes here instead: the procedure's name, the call's location and
  whether the call was in tail position. The history is a ring buffer
  of the last `depth` applications, so a long tail-recursive loop
  overwrites its oldest entries rather than growing it.

  The history follows the script's dynamic extent. A call that is not
  in tail position saves the history before it applies the procedure
  and restores it when the procedure returns, so the entries made
  during that call are dropped once it has finished. A primitive
  restores it when it returns too, which covers procedures it calls
  back (`map`, `call/cc`, `with-exception-handler`, ...). `guard`
  restores it when it catches a raise, so an escape never leaves frames
  from the abandoned extent behind. What remains when an error escapes
  is the chain of calls that were still running, each followed by the
  tail calls it made, most recent first.

  The buffer is an immutable tuple, so a saved history is unaffected
  by later calls and restoring one is a single `Process.put/2`. Each
  entry copies the tuple, which bounds both the memory the history
  holds and the cost of a call by `depth`.

  Nothing is recorded unless the entry point has called `reset/1` with
  a depth, which `Schooner.eval/3` and `Schooner.run_compiled/3` do
  only with `debug: true`. The state is reset by the same
  snapshot/restore that applies to `Schooner.Eval.ExceptionState`.
  """

  alias Schooner.Expander.SyntaxRules
  alias Schooner.Frame
  alias Schooner.Location

  @key {__MODULE__, :history}
  @default_depth 32

  @typedoc "A saved history: `nil` when none is being kept."
  @type snapshot :: {non_neg_integer(), tuple()} | nil

  @doc "The number of applications kept when no `:backtrace_depth` is given."
  @spec default_depth() :: pos_integer()
  def default_depth, do: @default_depth

  @doc """
  Start an empty history of `depth` entries, or stop keeping one when
  `depth` is `nil`.
  """
  @spec reset(pos_integer() | nil) :: :ok
  def reset(nil) do
    Process.delete(@key)
    :ok
  end

  def reset(depth) when is_integer(depth) and depth > 0 do
    Process.put(@key, {0, :erlang.make_tuple(depth, nil)})
    :ok
  end

  @doc "The current history, for `restore/1`."
  @spec snapshot() :: snapshot()
  def snapshot, do: Process.get(@key)

  @doc "Put back a history saved by `snapshot/0`."
  @spec restore(snapshot()) :: :ok
  def restore(nil) do
    Process.delete(@key)
    :ok
  end

  def restore(history) do
    Process.put(@key, history)
    :ok
  end

  @doc """
  Record an application of the procedure named `name` (`nil` for an
  anonymous one) at `loc` on top of `history`, the current history as
  returned by `snapshot/0`. Taking it from the caller saves a read
  when the caller needs the snapshot anyway. Does nothing when no
  history is being kept.
  """
  @spec push(snapshot(), binary() | nil, Location.t() | nil, boolean()) :: :ok
  def push(nil, _name, _loc, _tail?), do: :ok

  def push({count, ring}, name, loc, tail?) do
    slot = rem(count, tuple_size(ring))
    Process.put(@key, {count + 1, put_elem(ring, slot, {name, loc, tail?})})
    :ok
  end

  @doc """
  The recorded applications as `Schooner.Frame`s, most recent first, or
  `nil` when no history is being kept.
  """
  @spec frames() :: [Frame.t()] | nil
  def frames do
    case Process.get(@key) do
      nil ->
        nil

      {count, ring} ->
        size = tuple_size(ring)

        for i <- (count - 1)..max(count - size, 0)//-1 do
          {name, loc, tail?} = elem(ring, rem(i, size))
          %Frame{name: display_name(name), location: loc, tail?: tail?}
        end
    end
  end

  @doc """
  Give `exception` the current history as its `:scheme_backtrace`,
  unless it already has one or no history is being kept. Exceptions
  without the field pass through unchanged.
  """
  @spec attach(Exception.t()) :: Exception.t()
  def attach(%{scheme_backtrace: nil} = exception) do
    case frames() do
      nil -> exception
      frames -> %{exception | scheme_backtrace: frames}
    end
  end

  def attach(exception), do: exception

  # Names minted by a macro expansion carry a hygiene mark; show the
  # name the user wrote.
  defp display_name(nil), do: "<lambda>"

  defp display_name(name) do
    case SyntaxRules.strip_mark(name) do
      {:ok, base} -> base
      :error -> name
    end
  end
end
