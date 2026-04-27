defmodule Schooner.Expander.SyntaxEnv do
  @moduledoc """
  Compile-time environment used by `Schooner.Expander`.

  Holds two kinds of bindings:

    * **Macros** — a transformer function and a set of "literals" used by
      `syntax-rules` to recognise constants in patterns. Transformers are
      stored both globally (top-level `define-syntax`) and per-frame
      (`let-syntax`, `letrec-syntax`).
    * **Variables** — names bound as runtime values (lambda parameters,
      `define`s, `let`s after expansion). The expander records these only
      so that an inner `let` shadowing a macro keyword does the right
      thing: an enclosed reference resolves as a variable rather than as
      the outer macro.

  Frames are kept innermost-first. Resolution walks the lex frames and
  then the global map. Globals are intentionally a plain map rather than
  ETS — the syntax env is purely functional in the expander, threaded
  through top-level forms.
  """

  @type transformer :: (term() -> term())
  @type binding ::
          {:macro, transformer()}
          | :variable
  @type frame :: %{optional(binary()) => binding()}
  @type t :: %__MODULE__{globals: frame(), lex: [frame()]}

  defstruct globals: %{}, lex: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Resolve a name to its binding kind. Returns `:undefined` if the name
  is not bound as a syntax keyword or as a variable in any visible
  frame; the caller should treat that as a runtime free reference.
  """
  @spec lookup(t(), binary()) :: binding() | :undefined
  def lookup(%__MODULE__{lex: lex, globals: g}, name) when is_binary(name) do
    case lex_lookup(lex, name) do
      {:ok, binding} -> binding
      :error -> Map.get(g, name, :undefined)
    end
  end

  defp lex_lookup([], _name), do: :error

  defp lex_lookup([frame | rest], name) do
    case Map.fetch(frame, name) do
      {:ok, _} = ok -> ok
      :error -> lex_lookup(rest, name)
    end
  end

  @doc """
  Return a new env with `name` bound at top level to `transformer`.

  Used for top-level `define-syntax`. Idempotently overwrites a
  pre-existing binding under the same name (consistent with
  `Env.define/3` for runtime values).
  """
  @spec define_macro(t(), binary(), transformer()) :: t()
  def define_macro(%__MODULE__{globals: g} = env, name, transformer)
      when is_binary(name) and is_function(transformer, 1) do
    %{env | globals: Map.put(g, name, {:macro, transformer})}
  end

  @doc """
  Push a fresh lexical frame containing the given macro bindings. Used
  by `let-syntax` and `letrec-syntax`.
  """
  @spec push_macros(t(), [{binary(), transformer()}]) :: t()
  def push_macros(%__MODULE__{lex: lex} = env, bindings) do
    frame = Map.new(bindings, fn {name, t} -> {name, {:macro, t}} end)
    %{env | lex: [frame | lex]}
  end

  @doc """
  Push a fresh lexical frame marking the given names as variables. Used
  when entering a `lambda`, `let`, etc., so that an enclosed reference
  to a name shadowed by the lex binding is not later interpreted as a
  reference to an outer macro of the same name.
  """
  @spec push_variables(t(), [binary()]) :: t()
  def push_variables(%__MODULE__{lex: lex} = env, names) when is_list(names) do
    frame = Map.new(names, &{&1, :variable})
    %{env | lex: [frame | lex]}
  end
end
