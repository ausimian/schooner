defmodule Schooner do
  @moduledoc """
  An embeddable, sandboxed Scheme interpreter for the BEAM, targeting
  the r7rs-small language minus its mutable operations.

  The pipeline is `Schooner.Lexer` → `Schooner.Reader` →
  `Schooner.Expander` → `Schooner.Eval`, with `Schooner.Value` providing
  the tagged-term value model and `Schooner.Env` the
  immutable-with-mutable-globals runtime environment. Macro bindings
  live in a separate `Schooner.Expander.SyntaxEnv` threaded through
  expansion only.

  ## Choosing an entry point

  Schooner's entry points come in pairs following the Elixir
  convention: a tagged-tuple form (`run/1`, `eval/2,3`) and a bang
  form (`run!/1`, `eval!/2,3`) that raises on failure. Picking
  between `run*` and `eval*` is a **trust-posture decision** — the
  naming is the opposite of what reflex suggests.

  | Family        | Auto-imports                                                                              | Trust posture                                       | Use for                                                            |
  | ---           | ---                                                                                       | ---                                                 | --- |
  | `run/1`/`run!/1`     | injects `(import ...)` of every shipped standard library when the script declares none | **Not sandbox-safe.** Every shipped primitive is in scope by default. | tests, REPL-style use, your own scripts where you control the source |
  | `eval/2,3`/`eval!/2,3` | none — bindings come exclusively from the `env` argument and the script's own `(import ...)` declarations | **Sandbox-safe.** The embedder controls the surface. | embedding untrusted or semi-trusted scripts |

  The implicit-import behaviour of `run`/`run!` is opt-in via the
  `implicit_imports: :all` option on the 3-arity `eval/3` and
  `eval!/3`. Embedders who want the convenience without the rename
  can call `eval!/3` (or `eval/3`) with the option themselves.

  Within each family, the bang form raises one of:

    * `Schooner.Error` — uncaught Scheme `(raise ...)` in the script
    * `Schooner.Eval.Error` — runtime evaluation failure
    * `Schooner.Primitive.Error` — primitive type / arity / domain error
    * `Schooner.Library.NotFoundError` — `(import ...)` of a missing library
    * `Schooner.Lexer.Error`, `Schooner.Reader.Error`,
      `Schooner.Expander.Error` — source-level failures

  The non-bang form returns `{:ok, value}` on success or
  `{:error, exception}` for any of the above. `ArgumentError`
  raised by malformed options is **not** caught — that is an
  embedder bug, not a script-level failure.

  ### Embedding untrusted code

  Use `eval/2` (or `eval!/2`) and require the script to declare
  exactly which libraries it needs. A script that omits
  `(import ...)` cannot reach any primitive — even `+` is unbound:

      iex> Schooner.eval!("(import (only (scheme base) +)) (+ 1 2)", Schooner.Env.new())
      3

  Pair this with BEAM-level resource limits — run `eval!/2` inside
  a spawned process with `:max_heap_size` and a `Task.shutdown/2`
  timeout so a runaway script cannot exhaust the host.

  For richer sandbox composition (registering host libraries,
  pre-imports, etc.), construct a `Schooner.Environment` via
  `Schooner.Environment.new/1` and pass it to `eval/2`.
  """

  alias Schooner.Env
  alias Schooner.Environment
  alias Schooner.Eval
  alias Schooner.Eval.ContinuationState
  alias Schooner.Eval.ExceptionState
  alias Schooner.Eval.ParameterState
  alias Schooner.Expander
  alias Schooner.Library
  alias Schooner.Library.Import, as: LibImport
  alias Schooner.Reader
  alias Schooner.Value

  # Exception types caught by the tagged-tuple wrappers and surfaced
  # as `{:error, exception}`. Anything else propagates — those are
  # embedder bugs (e.g. ArgumentError on malformed options) and
  # should not be silently swallowed.
  @script_exceptions [
    Schooner.Error,
    Schooner.Eval.Error,
    Schooner.Primitive.Error,
    Schooner.Library.NotFoundError,
    Schooner.Lexer.Error,
    Schooner.Reader.Error,
    Schooner.Expander.Error
  ]

  # Implicit imports applied when `implicit_imports: :all` is set and
  # the script has no explicit `(import ...)` of its own. Pre-parsed at
  # compile time so the option path does not pay reader cost on every
  # call.
  @default_implicit_imports_forms Reader.read_string(
                                    "(import (scheme base) (scheme cxr) (scheme char) " <>
                                      "(scheme inexact) (scheme complex) (scheme write) " <>
                                      "(scheme read) (scheme case-lambda) (scheme lazy))"
                                  )

  @doc """
  Read and evaluate `source` in a fresh empty env, with every shipped
  standard library implicitly imported when the script declares no
  imports of its own.

  Returns `{:ok, value}` on success, `{:error, exception}` for
  any script-level failure. Use `run!/1` for the raising variant.

  **Not for untrusted input.** A script with no `(import ...)`
  form reaches every primitive Schooner ships with. Use `eval/2`
  for embedding scripts you do not control — see "Choosing an
  entry point" in the moduledoc.
  """
  @spec run(binary()) :: {:ok, Value.t()} | {:error, Exception.t()}
  def run(source) when is_binary(source) do
    {:ok, run!(source)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Bang form of `run/1` — raises on script-level failure.
  """
  @spec run!(binary()) :: Value.t()
  def run!(source) when is_binary(source) do
    eval!(source, Env.new(), implicit_imports: :all)
  end

  @doc """
  Read and evaluate `source` against `env`, threading top-level
  definitions and any explicit `(import ...)` bindings into it.

  Returns `{:ok, value}` on success, `{:error, exception}` for
  any script-level failure. Use `eval!/2` for the raising variant.

  `env` may be either a `Schooner.Env` (low-level) or a
  `Schooner.Environment` (the embedding-friendly bundle of env +
  registry + syntax env produced by `Schooner.Environment.new/1`).
  When given an `Env`, no implicit imports are added — bindings
  come exclusively from `env` and the script's own `(import ...)`
  declarations.

  This is the strict path: it is the right entry point for
  embedding scripts whose source the host does not control. See
  "Choosing an entry point" in the moduledoc.
  """
  @spec eval(binary(), Env.t() | Environment.t()) ::
          {:ok, Value.t()} | {:error, Exception.t()}
  def eval(source, env_or_environment) do
    {:ok, eval!(source, env_or_environment)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Read and evaluate `source` against `env` with `opts`. Returns
  `{:ok, value}` on success, `{:error, exception}` for any
  script-level failure. Use `eval!/3` for the raising variant.

  Options match `eval!/3`. The `Environment` overload of `eval/2`
  does not accept options — pre-imports and library composition
  are baked into the `Environment` at construction time.
  """
  @spec eval(binary(), Env.t(), keyword()) ::
          {:ok, Value.t()} | {:error, Exception.t()}
  def eval(source, %Env{} = env, opts) when is_binary(source) and is_list(opts) do
    {:ok, eval!(source, env, opts)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Bang form of `eval/2` — raises on script-level failure.
  """
  @spec eval!(binary(), Env.t() | Environment.t()) :: Value.t()
  def eval!(source, %Env{} = env) when is_binary(source) do
    eval!(source, env, [])
  end

  def eval!(source, %Environment{env: env, syntax_env: syntax_env, registry: registry})
      when is_binary(source) do
    forms = Reader.read_string(source)
    do_eval(forms, env, syntax_env, registry)
  end

  @doc """
  Bang form of `eval/3` — raises on script-level failure.

  Options:

    * `:implicit_imports` — controls implicit imports prepended
      to a script that declares none of its own.
        * `:none` (default) — no implicit imports. Bindings come
          exclusively from `env` and the script's own
          `(import ...)` declarations. Use this for untrusted
          input.
        * `:all` — implicitly import every shipped standard
          library. Skipped if the script already declares any
          `(import ...)`, on the principle that an explicit
          import means the user has opted in to a tighter
          surface.
  """
  @spec eval!(binary(), Env.t(), keyword()) :: Value.t()
  def eval!(source, %Env{} = env, opts) when is_binary(source) and is_list(opts) do
    forms = Reader.read_string(source)
    forms = apply_implicit_imports(forms, opts)
    do_eval(forms, env, Expander.bootstrap_env(), Library.standard())
  end

  defp apply_implicit_imports(forms, opts) do
    case Keyword.get(opts, :implicit_imports, :none) do
      :none ->
        forms

      :all ->
        {explicit_imports, _body} = LibImport.extract_program_imports(forms)

        case explicit_imports do
          [] -> @default_implicit_imports_forms ++ forms
          _ -> forms
        end

      other ->
        raise ArgumentError,
              "invalid value for :implicit_imports — expected :none or :all, got: " <>
                inspect(other)
    end
  end

  defp do_eval(forms, %Env{} = env, syntax_env, registry) do
    # Snapshot/restore the per-process control state so each top-level
    # call starts clean. Without this, a script that pushes a handler
    # or registers a `call/cc` tag then escapes via a host-side throw
    # (e.g. a test that catches `Schooner.Error`) would leak state into
    # the next call in the same process.
    prev_handlers = ExceptionState.snapshot()
    prev_conts = ContinuationState.snapshot()
    prev_params = ParameterState.snapshot()
    ExceptionState.reset()
    ContinuationState.reset()
    ParameterState.reset()

    try do
      {import_specs, body} = LibImport.extract_program_imports(forms)
      bindings = LibImport.resolve(import_specs, registry)

      {env, syntax_env} = LibImport.apply_bindings(bindings, env, syntax_env)

      body
      |> Expander.expand_program(syntax_env)
      |> Enum.reduce(:unspecified, fn form, _acc -> Eval.eval(form, env) end)
      |> Eval.single_value!()
    after
      ExceptionState.restore(prev_handlers)
      ContinuationState.restore(prev_conts)
      ParameterState.restore(prev_params)
    end
  end

  defp rescue_script_error(e, stacktrace) do
    if e.__struct__ in @script_exceptions do
      {:error, e}
    else
      reraise e, stacktrace
    end
  end
end
