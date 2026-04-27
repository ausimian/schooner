defmodule Schooner.Env do
  @moduledoc """
  Immutable-ish environment for the Scheme evaluator.

  An environment is a chain of lexical frames innermost-first plus a
  *globals* table identified by an `:ets` table id. Lexical frames are
  immutable maps; new frames are pushed by `extend/2`. The globals
  table is mutable in the strict sense — `define/3` writes to it — so
  closures that captured an env see top-level definitions added after
  they were created. This is the standard `letrec`-style knot-tying
  applied to the top-level frame: closures reference the frame by
  identity, not by value-at-bind-time.

  The globals table is owned by the process that calls `new/0` and is
  GC'd when that process exits, so per-execution sandboxing falls out
  of the BEAM's process model.
  """

  alias Schooner.Value

  @enforce_keys [:globals, :lex]
  defstruct [:globals, :lex]

  @type frame :: %{optional(binary()) => Value.t()} | {:rec, reference()}
  @type t :: %__MODULE__{globals: :ets.tid(), lex: [frame()]}

  @spec new() :: t()
  def new do
    table = :ets.new(:schooner_globals, [:set, :protected])
    %__MODULE__{globals: table, lex: []}
  end

  @doc "Look up `name`. Walks lexical frames innermost-first, then globals."
  @spec lookup(t(), binary()) :: {:ok, Value.t()} | :error
  def lookup(%__MODULE__{lex: lex, globals: globals}, name) when is_binary(name) do
    case lex_lookup(lex, name) do
      {:ok, _} = ok -> ok
      :error -> globals_lookup(globals, name)
    end
  end

  defp lex_lookup([], _name), do: :error

  defp lex_lookup([{:rec, ref} | rest], name) do
    case Map.fetch(Process.get(ref), name) do
      {:ok, _} = ok -> ok
      :error -> lex_lookup(rest, name)
    end
  end

  defp lex_lookup([frame | rest], name) do
    case Map.fetch(frame, name) do
      {:ok, _} = ok -> ok
      :error -> lex_lookup(rest, name)
    end
  end

  defp globals_lookup(table, name) do
    case :ets.lookup(table, name) do
      [{^name, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @doc """
  Add or replace a top-level binding. Visible to every closure that
  captured this env, regardless of when it was created.
  """
  @spec define(t(), binary(), Value.t()) :: t()
  def define(%__MODULE__{globals: globals} = env, name, value) when is_binary(name) do
    :ets.insert(globals, {name, value})
    env
  end

  @doc "Push a new lexical frame on top of `env`."
  @spec extend(t(), [{binary(), Value.t()}]) :: t()
  def extend(%__MODULE__{lex: lex} = env, bindings) do
    %{env | lex: [Map.new(bindings) | lex]}
  end

  @doc """
  Push a fresh `letrec`-style frame whose bindings can be assigned later
  via `rec_set/3`. Closures created against the returned env see the
  bindings by frame identity, so forward references resolve once the
  frame has been populated. Backed by a process-dictionary slot keyed by
  a fresh reference; the slot is process-local and is GC'd with the
  owning process.
  """
  @spec extend_rec(t(), [binary()]) :: t()
  def extend_rec(%__MODULE__{lex: lex} = env, names) when is_list(names) do
    ref = make_ref()
    Process.put(ref, Map.new(names, fn name when is_binary(name) -> {name, :unspecified} end))
    %{env | lex: [{:rec, ref} | lex]}
  end

  @doc "Set a binding in the topmost recursive frame on `env`."
  @spec rec_set(t(), binary(), Value.t()) :: t()
  def rec_set(%__MODULE__{lex: [{:rec, ref} | _]} = env, name, value) when is_binary(name) do
    Process.put(ref, Map.put(Process.get(ref), name, value))
    env
  end

  @doc "Pop the topmost lexical frame on `env`."
  @spec pop(t()) :: t()
  def pop(%__MODULE__{lex: [_top | rest]} = env), do: %{env | lex: rest}
end
