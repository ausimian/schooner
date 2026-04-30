defmodule Schooner do
  @moduledoc """
  An embeddable, sandboxed Scheme interpreter for the BEAM, targeting the
  r7rs-small language minus its mutable operations.

  The pipeline is `Schooner.Lexer` → `Schooner.Reader` →
  `Schooner.Expander` → `Schooner.Eval`, with `Schooner.Value` providing
  the tagged-term value model and `Schooner.Env` the
  immutable-with-mutable-globals runtime environment. Macro bindings
  live in a separate `Schooner.Expander.SyntaxEnv` threaded through
  expansion only.

  ## Choosing an entry point

  Schooner has two top-level evaluation entry points. **The trust
  posture differs — picking the wrong one for untrusted input is a
  sandbox-shaped hole.** The naming is the opposite of what reflex
  suggests: `run/1` is the lax convenience, `eval/2` is the strict
  embedding path.

  | Entry point | Auto-imports | Trust posture | Use for |
  | ---         | ---          | ---           | --- |
  | `run/1`     | injects `(import ...)` of every shipped standard library when the script declares none | **Not sandbox-safe.** Every shipped primitive is in scope by default. | tests, REPL-style use, your own scripts where you control the source |
  | `eval/2`    | none — bindings come exclusively from `env` and the script's own `(import ...)` declarations | **Sandbox-safe.** The embedder controls the surface. | embedding untrusted or semi-trusted scripts |

  The implicit-import behaviour of `run/1` is opt-in via the
  `implicit_imports: :all` option on `eval/3`; `run/1` is exactly
  `eval(source, Env.new(), implicit_imports: :all)`. Embedders who want
  the convenience without the rename can call `eval/3` with the option
  themselves.

  ### Embedding untrusted code

  Use `eval/2` and require the script to declare exactly which libraries
  it needs. A script that omits `(import ...)` cannot reach any
  primitive — even `+` is unbound:

      iex> Schooner.eval("(import (only (scheme base) +)) (+ 1 2)", Schooner.Env.new())
      3

  Pair this with BEAM-level resource limits — run `eval/2` inside a
  spawned process with `:max_heap_size` and a `Task.shutdown/2` timeout
  so a runaway script cannot exhaust the host.

  The full embedding API (`Schooner.Environment.new/1`,
  `Schooner.compile/1`, `Schooner.Host`) arrives in phase 14.
  """

  alias Schooner.Env
  alias Schooner.Eval
  alias Schooner.Eval.ContinuationState
  alias Schooner.Eval.ExceptionState
  alias Schooner.Eval.ParameterState
  alias Schooner.Expander
  alias Schooner.Library
  alias Schooner.Library.Import, as: LibImport
  alias Schooner.Reader
  alias Schooner.Value

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

  This is a one-line convenience over `eval/3`:

      Schooner.eval(source, Schooner.Env.new(), implicit_imports: :all)

  **Not for untrusted input.** A script with no `(import ...)` form
  reaches every primitive Schooner ships with. Use `eval/2` for
  embedding scripts you do not control — see "Choosing an entry point"
  in the moduledoc.
  """
  @spec run(binary()) :: Value.t()
  def run(source) when is_binary(source) do
    eval(source, Env.new(), implicit_imports: :all)
  end

  @doc """
  Read and evaluate `source` against `env`, threading top-level
  definitions and any explicit `(import ...)` bindings into it. No
  implicit imports are added — bindings come exclusively from `env`
  and from the script's own `(import ...)` declarations.

  This is the strict path: it is the right entry point for embedding
  scripts whose source the host does not control. See "Choosing an
  entry point" in the moduledoc.

  Equivalent to `eval(source, env, [])`.
  """
  @spec eval(binary(), Env.t()) :: Value.t()
  def eval(source, %Env{} = env) when is_binary(source) do
    eval(source, env, [])
  end

  @doc """
  Read and evaluate `source` against `env` with `opts`.

  Options:

    * `:implicit_imports` — controls implicit imports prepended to a
      script that declares none of its own.
        * `:none` (default) — no implicit imports. Bindings come
          exclusively from `env` and the script's own
          `(import ...)` declarations. Use this for untrusted input.
        * `:all` — implicitly import every shipped standard library.
          Skipped if the script already declares any `(import ...)`,
          on the principle that an explicit import means the user has
          opted in to a tighter surface.
  """
  @spec eval(binary(), Env.t(), keyword()) :: Value.t()
  def eval(source, %Env{} = env, opts) when is_binary(source) and is_list(opts) do
    forms = Reader.read_string(source)

    forms =
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

    do_eval(forms, env)
  end

  defp do_eval(forms, %Env{} = env) do
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
      bindings = LibImport.resolve(import_specs, Library.standard())

      {env, syntax_env} =
        LibImport.apply_bindings(bindings, env, Expander.bootstrap_env())

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
end
