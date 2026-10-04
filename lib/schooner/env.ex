defmodule Schooner.Env do
  @moduledoc """
  Environment for the Scheme evaluator: immutable lexical frames over
  a mutable globals table.

  An environment is a chain of lexical frames innermost-first plus a
  *globals* slot identified by a process-dictionary key (a fresh
  reference). Lexical frames are immutable; new frames are pushed by
  `extend/2` (or, inside the evaluator, `push_frame/2`). The globals
  slot is mutable in the strict sense — `define/3` writes to it — so
  closures that captured an env see top-level definitions added after
  they were created. This is the standard `letrec`-style knot-tying
  applied to the top-level frame: closures reference the frame by
  identity, not by value-at-bind-time.

  Globals live in the process dictionary, not in `:ets`, so
  consecutive lookups of the same name return the *same* heap term.
  This preserves `erts_debug.same/2` identity for aggregates bound
  at top level — `(eq? x x)` answers `#t` for vectors, pairs,
  parameters, and other aggregates, matching the lexical case.

  Each global has its own *cell*: a process-dictionary entry keyed by
  a fresh reference, holding the value. The globals slot maps names to
  cells. The evaluator resolves a global reference to its cell once,
  when it compiles the reference, so reading a global at run time is a
  single process-dictionary get rather than a lookup by name. A cell
  is created the first time a name is defined or compiled as a
  reference, and holds an "unbound" sentinel until it is defined.

  The globals slot is owned by the process that calls `new/0` and is
  reclaimed when that process exits, so per-execution sandboxing
  falls out of the BEAM's process model.

  ## Frame shapes

  The evaluator resolves every lexical variable reference to a
  `{depth, slot}` address at analysis time (see
  `Schooner.Eval.Analyze`), so the frames it pushes are *positional*:
  a tuple whose element 0 is a tuple of the frame's names and whose
  remaining elements are the values in the same order. The names are
  carried so `lookup/2` can still resolve by name; the evaluator
  itself only indexes.

  `extend/2` pushes a name → value map frame instead. Both shapes, and
  the recursive frames below, are understood by `lookup/2`.

  ## Recursive lexical frames

  `letrec`, `letrec*`, named `let`, and the `letrec*` produced by
  internal-define splicing each push a *recursive* frame, unless the
  evaluator has compiled the form to direct calls or proved that its
  targets are distinct and every initializer reference to the same
  frame targets an earlier binding, including references inside nested
  procedures. Those forms use immutable positional frames: init
  closures capture the earlier values, and body closures capture the
  fully initialized frame. These snapshots live as long as the closures
  that reference them and need no process-dictionary slot or cleanup.

  Duplicate targets and initializer references to their own or later
  bindings still need recursive frames unless compiled to direct calls.
  A recursive frame is a process-dictionary slot keyed by `make_ref/0`,
  holding the frame's names and a tuple of values, so closures captured
  during init evaluation see later bindings via frame identity.

  Each such frame is released by `release_rec/1` when the body
  finishes — *unless* the body's return value carries a closure whose
  env still names the frame. In that case the evaluator detects the
  escape and leaves the slot alive holding the now-finalised
  snapshot, so the escaped closure (and any closures it reaches via
  rec lookups, including mutually-recursive bindings) can resolve
  rec names through the slot for the rest of the process lifetime.
  Slot leakage is therefore bounded to *actual* closure escapes — a
  letrec form whose body returns a non-closure value (the dominant
  case in typical Scheme code, including all named-let recursion
  whose body is `(tag val ...)`) releases its slot as usual.
  """

  alias Schooner.Value

  # Sentinel held in a recursive frame for a binding whose init has
  # not yet been evaluated. Distinct from any user-constructible value
  # so a forward reference within an init can be flagged as a runtime
  # error rather than silently returning `:unspecified`.
  @rec_uninitialised :__schooner_rec_uninitialised__

  # Held in a global's cell before the name is defined.
  @unbound :__schooner_unbound__

  @enforce_keys [:globals, :lex]
  defstruct [:globals, :lex]

  @type frame :: %{optional(binary()) => Value.t()} | tuple() | {:rec, reference()}
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
    # `Process.get(ref)` returns `nil` once `release_rec/1` has
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

      {:rec_frame, names, values} ->
        case rec_slot(names, name) do
          nil -> lex_lookup(rest, name)
          i -> rec_value(elem(values, i), name)
        end
    end
  end

  defp lex_lookup([frame | rest], name) when is_map(frame) do
    case Map.fetch(frame, name) do
      {:ok, _} = ok -> ok
      :error -> lex_lookup(rest, name)
    end
  end

  # Positional frame: `{names, v1, v2, ...}`. Duplicate names resolve
  # to the last occurrence, matching the map-frame semantics of
  # binding the same name twice.
  defp lex_lookup([frame | rest], name) when is_tuple(frame) do
    case last_index(elem(frame, 0), name) do
      nil -> lex_lookup(rest, name)
      i -> {:ok, elem(frame, i + 1)}
    end
  end

  defp rec_value(@rec_uninitialised, name), do: {:uninitialised, name}
  defp rec_value(value, _name), do: {:ok, value}

  defp globals_lookup(ref, name) do
    with {:ok, cell} <- :maps.find(name, :erlang.get(ref)) do
      case :erlang.get(cell) do
        @unbound -> :error
        value -> {:ok, value}
      end
    end
  end

  @doc false
  @spec fetch_global(t(), binary()) :: {:ok, Value.t()} | :error
  def fetch_global(%__MODULE__{globals: ref}, name), do: globals_lookup(ref, name)

  @doc false
  # Every defined global, as a map of name to value. Raises
  # `ArgumentError` when the env was built by another process.
  @spec globals(t()) :: %{binary() => Value.t()}
  def globals(%__MODULE__{globals: ref}) do
    case :erlang.get(ref) do
      :undefined ->
        raise ArgumentError, "the environment was built by another process"

      cells ->
        for {name, cell} <- cells, (value = :erlang.get(cell)) != @unbound, into: %{} do
          {name, value}
        end
    end
  end

  @doc """
  Add or replace a top-level binding. Visible to every closure that
  captured this env, regardless of when it was created.
  """
  @spec define(t(), binary(), Value.t()) :: t()
  def define(%__MODULE__{globals: ref} = env, name, value) when is_binary(name) do
    :erlang.put(global_cell(ref, name), value)
    env
  end

  @doc false
  # The cell holding global `name` in the globals slot `ref`, created
  # (unbound) if the name has none yet.
  @spec global_cell(reference(), binary()) :: reference()
  def global_cell(ref, name) when is_binary(name) do
    cells = :erlang.get(ref)

    case cells do
      %{^name => cell} ->
        cell

      _ ->
        cell = make_ref()
        :erlang.put(cell, @unbound)
        :erlang.put(ref, Map.put(cells, name, cell))
        cell
    end
  end

  @doc false
  @spec unbound() :: atom()
  def unbound, do: @unbound

  @doc "Push a new lexical frame on top of `env`."
  @spec extend(t(), [{binary(), Value.t()}]) :: t()
  def extend(%__MODULE__{lex: lex} = env, bindings) do
    %{env | lex: [Map.new(bindings) | lex]}
  end

  @doc false
  # Push a positional frame `{names_tuple, v1, v2, ...}`. Used by the
  # evaluator, whose variable references are pre-resolved to slots.
  @spec push_frame(t(), tuple()) :: t()
  def push_frame(%__MODULE__{lex: lex} = env, frame) when is_tuple(frame) do
    %{env | lex: [frame | lex]}
  end

  @doc """
  Push a fresh `letrec`-style frame whose bindings start uninitialised
  and can be assigned later via `rec_set/3`. Closures created against
  the returned env see the bindings by frame identity, so forward
  references resolve once the frame has been populated. Backed by a
  process-dictionary slot keyed by a fresh reference; the slot must
  be released with `release_rec/1` once the binding form's body has
  finished evaluating.

  Duplicate names share one slot.
  """
  @spec extend_rec(t(), [binary()]) :: t()
  def extend_rec(%__MODULE__{lex: lex} = env, names) when is_list(names) do
    names = Enum.uniq(names)
    true = Enum.all?(names, &is_binary/1)
    ref = make_ref()
    values = :erlang.make_tuple(length(names), @rec_uninitialised)
    Process.put(ref, {:rec_frame, List.to_tuple(names), values})
    %{env | lex: [{:rec, ref} | lex]}
  end

  @doc "Set a binding in the topmost recursive frame on `env`."
  @spec rec_set(t(), binary(), Value.t()) :: t()
  def rec_set(%__MODULE__{lex: [{:rec, ref} | _]} = env, name, value) when is_binary(name) do
    {:rec_frame, names, _} = Process.get(ref)
    rec_put(env, rec_slot(names, name), value)
  end

  @doc false
  # Set slot `index` (0-based, in `extend_rec/2`'s de-duplicated name
  # order) of the topmost recursive frame on `env`.
  @spec rec_put(t(), non_neg_integer(), Value.t()) :: t()
  def rec_put(%__MODULE__{lex: [{:rec, ref} | _]} = env, index, value) do
    {:rec_frame, names, values} = :erlang.get(ref)
    :erlang.put(ref, {:rec_frame, names, put_elem(values, index, value)})
    env
  end

  @doc false
  @spec rec_uninitialised() :: atom()
  def rec_uninitialised, do: @rec_uninitialised

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

  defp rec_slot(names, name), do: first_index(names, name, 0, tuple_size(names))

  defp first_index(_names, _name, i, n) when i == n, do: nil

  defp first_index(names, name, i, n) do
    if elem(names, i) == name, do: i, else: first_index(names, name, i + 1, n)
  end

  defp last_index(names, name), do: last_index(names, name, tuple_size(names) - 1)

  defp last_index(_names, _name, -1), do: nil

  defp last_index(names, name, i) do
    if elem(names, i) == name, do: i, else: last_index(names, name, i - 1)
  end
end
