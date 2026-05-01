defmodule Schooner.Env do
  @moduledoc """
  Immutable-ish environment for the Scheme evaluator.

  An environment is a chain of lexical frames innermost-first plus a
  *globals* slot identified by a process-dictionary key (a fresh
  reference). Lexical frames are immutable maps; new frames are
  pushed by `extend/2`. The globals slot is mutable in the strict
  sense — `define/3` writes to it — so closures that captured an env
  see top-level definitions added after they were created. This is
  the standard `letrec`-style knot-tying applied to the top-level
  frame: closures reference the frame by identity, not by
  value-at-bind-time.

  Globals are stored as a Map on the process heap, not in `:ets`, so
  consecutive lookups of the same name return the *same* heap term.
  This preserves `:erts_debug.same/2` identity for aggregates bound
  at top level — `(eq? x x)` answers `#t` for vectors, pairs,
  parameters, and other aggregates, matching the lexical case.

  The globals slot is owned by the process that calls `new/0` and is
  reclaimed when that process exits, so per-execution sandboxing
  falls out of the BEAM's process model.

  ## Recursive lexical frames

  `letrec`, `letrec*`, named `let`, and the `letrec*` produced by
  internal-define splicing each push a *recursive* frame. A recursive
  frame is a map of name → value backed by a process-dictionary slot
  keyed by `make_ref/0`, so closures captured during init evaluation
  see later bindings via frame identity.

  Each such frame must be released by `release_rec/1` once the body of
  the binding form finishes evaluating. Closures that escape the body
  retain access to their rec bindings via a walk-and-rewrite step in
  the evaluator: at letrec exit the frame map is snapshotted into an
  immutable Elixir map and any closure in the body's return value
  whose env still names this frame is rebuilt to carry the snapshot
  directly, so subsequent applications resolve rec names without the
  released slot. Closures stored *inside* the snapshot keep their
  original `{:rec, ref}` env, so a chain of escape-then-apply that
  lands inside one of those snapshot-resident closures and from there
  references another rec binding will fall through to surrounding
  scope (e.g. globals) — i.e. mutually-recursive escape works only
  when each rec binding's referents are reachable from the snapshot's
  shape, not via the snapshot's own closures.
  """

  alias Schooner.Value

  # Sentinel held in a recursive frame for a binding whose init has
  # not yet been evaluated. Distinct from any user-constructible value
  # so a forward reference within an init can be flagged as a runtime
  # error rather than silently returning `:unspecified`.
  @rec_uninitialised :__schooner_rec_uninitialised__

  @enforce_keys [:globals, :lex]
  defstruct [:globals, :lex]

  @type frame :: %{optional(binary()) => Value.t()} | {:rec, reference()}
  @type t :: %__MODULE__{globals: reference(), lex: [frame()]}
  @type lookup_result :: {:ok, Value.t()} | :error | {:uninitialised, binary()}

  @spec new() :: t()
  def new do
    ref = make_ref()
    Process.put(ref, %{})
    %__MODULE__{globals: ref, lex: []}
  end

  @doc """
  Look up `name`. Walks lexical frames innermost-first, then globals.

  Returns `{:uninitialised, name}` when `name` is bound by an enclosing
  recursive frame whose init expression has not yet been evaluated;
  callers should treat this as a forward-reference runtime error.
  """
  @spec lookup(t(), binary()) :: lookup_result()
  def lookup(%__MODULE__{lex: lex, globals: globals}, name) when is_binary(name) do
    case lex_lookup(lex, name) do
      {:ok, _} = ok -> ok
      {:uninitialised, _} = u -> u
      :error -> globals_lookup(globals, name)
    end
  end

  defp lex_lookup([], _name), do: :error

  defp lex_lookup([{:rec, ref} | rest], name) do
    # `Process.get(ref)` returns `nil` once `with_rec_frame` has
    # released the slot, but closures created during the binding
    # form's body may still hold this dead frame in their captured
    # env. Fall through to the surrounding scope so a name that
    # resolves elsewhere (a global, an outer frame) still resolves
    # cleanly; an `unbound` raise from the outer `eval` is the only
    # observable difference for a name whose only binding *was* the
    # dead frame.
    case Process.get(ref) do
      nil ->
        lex_lookup(rest, name)

      {:rec_frame, frame} ->
        case Map.fetch(frame, name) do
          {:ok, @rec_uninitialised} -> {:uninitialised, name}
          {:ok, _} = ok -> ok
          :error -> lex_lookup(rest, name)
        end
    end
  end

  defp lex_lookup([frame | rest], name) do
    case Map.fetch(frame, name) do
      {:ok, _} = ok -> ok
      :error -> lex_lookup(rest, name)
    end
  end

  defp globals_lookup(ref, name) do
    case Map.fetch(Process.get(ref), name) do
      {:ok, _} = ok -> ok
      :error -> :error
    end
  end

  @doc """
  Add or replace a top-level binding. Visible to every closure that
  captured this env, regardless of when it was created.
  """
  @spec define(t(), binary(), Value.t()) :: t()
  def define(%__MODULE__{globals: ref} = env, name, value) when is_binary(name) do
    Process.put(ref, Map.put(Process.get(ref), name, value))
    env
  end

  @doc "Push a new lexical frame on top of `env`."
  @spec extend(t(), [{binary(), Value.t()}]) :: t()
  def extend(%__MODULE__{lex: lex} = env, bindings) do
    %{env | lex: [Map.new(bindings) | lex]}
  end

  @doc """
  Push a fresh `letrec`-style frame whose bindings start uninitialised
  and can be assigned later via `rec_set/3`. Closures created against
  the returned env see the bindings by frame identity, so forward
  references resolve once the frame has been populated. Backed by a
  process-dictionary slot keyed by a fresh reference; the slot must
  be released with `release_rec/1` once the binding form's body has
  finished evaluating.
  """
  @spec extend_rec(t(), [binary()]) :: t()
  def extend_rec(%__MODULE__{lex: lex} = env, names) when is_list(names) do
    ref = make_ref()

    Process.put(
      ref,
      {:rec_frame, Map.new(names, fn name when is_binary(name) -> {name, @rec_uninitialised} end)}
    )

    %{env | lex: [{:rec, ref} | lex]}
  end

  @doc "Set a binding in the topmost recursive frame on `env`."
  @spec rec_set(t(), binary(), Value.t()) :: t()
  def rec_set(%__MODULE__{lex: [{:rec, ref} | _]} = env, name, value) when is_binary(name) do
    {:rec_frame, frame} = Process.get(ref)
    Process.put(ref, {:rec_frame, Map.put(frame, name, value)})
    env
  end

  @doc """
  Release the topmost recursive frame on `env`, deleting the
  process-dictionary slot that backs it. Must be paired with
  `extend_rec/2`. Idempotent — releasing a frame whose slot was
  already deleted is a no-op.
  """
  @spec release_rec(t()) :: :ok
  def release_rec(%__MODULE__{lex: [{:rec, ref} | _]}) do
    Process.delete(ref)
    :ok
  end

  @doc "Pop the topmost lexical frame on `env`."
  @spec pop(t()) :: t()
  def pop(%__MODULE__{lex: [_top | rest]} = env), do: %{env | lex: rest}
end
