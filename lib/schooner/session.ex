defmodule Schooner.Session do
  @moduledoc ~S"""
  A sequence of evaluations against one `Schooner.Environment`, each
  seeing what the ones before it defined: the evaluation state behind
  `mix schooner.repl`, for building a console of your own.

      iex> session = Schooner.Session.new(Schooner.Environment.new(pre_imports: [["scheme", "base"]]))
      iex> {:ok, _, session} = Schooner.Session.eval(session, "(define x 41)")
      iex> {:ok, 42, _session} = Schooner.Session.eval(session, "(+ x 1)")

  `Schooner.eval/3` keeps a script's top-level `define`s and imported
  variables in the environment, but its `define-syntax` macros, and the
  macros its `(import ...)` forms bring in from a library such as one
  loaded with `Schooner.Library.Loader`, last only for that call. A
  session keeps them too, so a later evaluation can use a macro an
  earlier one defined or imported:

      iex> session = Schooner.Session.new(Schooner.Environment.new(pre_imports: [["scheme", "base"]]))
      iex> {:ok, _, session} =
      ...>   Schooner.Session.eval(session, "(define-syntax twice (syntax-rules () ((_ e) (begin e e))))")
      iex> {:ok, 3, _session} = Schooner.Session.eval(session, "(twice 1) 3")

  `eval/3` returns the next session whether the evaluation succeeded
  or not, and an error doesn't end the session. What the failing
  source did before the error stays done, as with `Schooner.eval/3`:
  the definitions it evaluated, and its imports and macros once they
  were read and resolved.

  As with `Schooner.Environment`, the session's definitions live in
  the dictionary of the process that built the environment, so use a
  session only from that process.

  The session's imports are resolved against the environment's
  registry, so a session can import only what a script evaluated with
  `Schooner.eval/3` against the same environment could.
  """

  alias Schooner.Environment
  alias Schooner.Value

  @enforce_keys [:environment, :opts]
  defstruct [:environment, :opts]

  @opaque t :: %__MODULE__{environment: Environment.t(), opts: keyword()}

  @doc """
  Start a session against `environment`.

  Options apply to every evaluation in the session:

    * `:debug` — as for `Schooner.eval/3`: locate errors raised while
      applying a procedure and attach a Scheme backtrace. Defaults to
      `false`.
    * `:backtrace_depth` — as for `Schooner.eval/3`.

  Errors are located in the source given to `eval/3` either way.
  """
  @spec new(Environment.t(), keyword()) :: t()
  def new(%Environment{} = environment, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, debug: false, backtrace_depth: nil)
    opts = Enum.reject(opts, fn {_, value} -> is_nil(value) end)
    %__MODULE__{environment: environment, opts: opts}
  end

  @doc """
  Read and evaluate `source` in `session`.

  Returns `{:ok, value, session}`, or `{:error, exception, session}`
  for any script-level failure, with the exceptions of
  `Schooner.eval/3`. Either way, pass the returned session to the
  next call.

  Options:

    * `:file` — the name of the source, recorded in the location of
      any error and prefixed to its message, as for `Schooner.eval/3`.
      Defaults to `nil`; the error's location then holds the line and
      column in `source`.
  """
  @spec eval(t(), binary(), keyword()) ::
          {:ok, Value.t(), t()} | {:error, Exception.t(), t()}
  def eval(%__MODULE__{} = session, source, opts \\ [])
      when is_binary(source) and is_list(opts) do
    opts = Keyword.validate!(opts, file: nil)
    %Environment{env: env, syntax_env: syntax_env, registry: registry} = session.environment
    eval_opts = [locations: true, file: opts[:file]] ++ session.opts

    {tag, result, syntax_env} =
      Schooner.session_eval(source, env, syntax_env, registry, eval_opts)

    session = put_in(session.environment.syntax_env, syntax_env)

    {tag, result, session}
  end

  @doc """
  The session's state as a `Schooner.Environment`, with the macros it
  has imported and defined: pass it to `Schooner.expand/3` or
  `Schooner.check/3` to see code as this session would.
  """
  @spec environment(t()) :: Environment.t()
  def environment(%__MODULE__{environment: environment}), do: environment

  @typedoc """
  A name in scope in a session, as listed by `bindings/1`.

    * `:name` — the name.
    * `:kind` — `:macro`, `:procedure`, or `:value`.
    * `:library` — the name of a library in the environment's
      registry that exports this binding under this name, such as
      `["scheme", "base"]`, or `nil` when none does: a definition made
      in the session, a binding from an anonymous library, or an
      import renamed with `prefix` or `rename`.
    * `:value` — the bound value, or `nil` for a macro.
  """
  @type binding :: %{
          name: binary(),
          kind: :macro | :procedure | :value,
          library: Schooner.Library.name() | nil,
          value: Value.t() | nil
        }

  @doc """
  Every name in scope in `session`, sorted by name: the variables the
  environment, imports and definitions bind, and the macros.

  A name that is both is listed as the macro, which is what a use of
  the name expands to: a variable keeps its value after a
  `define-syntax` of its name, and a macro keeps expanding after a
  definition of its name, as in a script evaluated with
  `Schooner.eval/3`.
  """
  @spec bindings(t()) :: [binding()]
  def bindings(%__MODULE__{environment: environment}) do
    %Environment{env: env, syntax_env: syntax_env, registry: registry} = environment
    exports = export_index(registry)

    macros =
      for {name, {:macro, transformer}} <- syntax_env.globals, into: %{} do
        {name,
         %{
           name: name,
           kind: :macro,
           library: library_of(exports, name, {:macro, transformer}),
           value: nil
         }}
      end

    variables =
      for {name, value} <- Schooner.Env.globals(env), into: %{} do
        kind = if Value.procedure?(value), do: :procedure, else: :value

        {name,
         %{
           name: name,
           kind: kind,
           library: library_of(exports, name, {:var, value}),
           value: value
         }}
      end

    variables
    |> Map.merge(macros)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  # Every export in `registry`, as a map from `{name, export}` to the
  # name of the library that exports it. Anonymous libraries were
  # applied when the environment was built and aren't in the registry.
  defp export_index(registry) do
    registry
    |> Enum.sort()
    |> Enum.reduce(%{}, fn {library, %{exports: exports}}, acc ->
      Enum.reduce(exports, acc, fn {name, export}, acc ->
        Map.put_new(acc, {name, export}, library)
      end)
    end)
  end

  defp library_of(exports, name, export), do: Map.get(exports, {name, export})
end
