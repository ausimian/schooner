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

  ## Entry points

    * `run/1` — convenience entry that pre-populates the environment
      via implicit `(import ...)` of every shipped standard library
      when the script has no explicit imports of its own. Use this
      from tests and quick-evaluations where ergonomics matter more
      than a tight surface.
    * `eval/2` — strict path: bindings only come from `(import ...)`
      declarations in the script source plus whatever is already in
      the supplied env. Use this when an embedder cares about which
      bindings a script can see.

  The full embedding API (`Schooner.Environment.new/1`,
  `Schooner.compile/1`, `Schooner.Host`) arrives in phase 14.
  """

  alias Schooner.Env
  alias Schooner.Eval
  alias Schooner.Eval.ContinuationState
  alias Schooner.Eval.ExceptionState
  alias Schooner.Expander
  alias Schooner.Library
  alias Schooner.Library.Import, as: LibImport
  alias Schooner.Reader
  alias Schooner.Value

  # Implicit imports applied by `run/1` when the script has no
  # explicit `(import ...)` of its own. Covers every standard library
  # shipped today so existing convenience callers see no behaviour
  # change after the boot-path flip.
  @default_run_imports "(import (scheme base) (scheme cxr) (scheme char) " <>
                         "(scheme inexact) (scheme write) (scheme read) " <>
                         "(scheme lazy))"

  @doc """
  Read and evaluate `source` in a fresh empty env. If `source`
  contains no top-level `(import ...)` declarations, an implicit
  import of every standard library is injected so quick-eval scripts
  can use `+`, `cond`, `display`, etc. without ceremony. Scripts that
  declare even a single explicit import skip the injection — the user
  has signalled they want to control the surface.
  """
  @spec run(binary()) :: Value.t()
  def run(source) when is_binary(source) do
    forms = Reader.read_string(source)
    {explicit_imports, _body} = LibImport.extract_program_imports(forms)

    forms =
      case explicit_imports do
        [] -> Reader.read_string(@default_run_imports) ++ forms
        _ -> forms
      end

    do_eval(forms, Env.new())
  end

  @doc """
  Read and evaluate `source` against `env`, threading top-level
  definitions and any explicit `(import ...)` bindings into it. No
  implicit imports are added — bindings come exclusively from `env`
  and from the script's own `(import ...)` declarations.
  """
  @spec eval(binary(), Env.t()) :: Value.t()
  def eval(source, %Env{} = env) when is_binary(source) do
    do_eval(Reader.read_string(source), env)
  end

  defp do_eval(forms, %Env{} = env) do
    # Snapshot/restore the per-process control state so each top-level
    # call starts clean. Without this, a script that pushes a handler
    # or registers a `call/cc` tag then escapes via a host-side throw
    # (e.g. a test that catches `Schooner.Error`) would leak state into
    # the next call in the same process.
    prev_handlers = ExceptionState.snapshot()
    prev_conts = ContinuationState.snapshot()
    ExceptionState.reset()
    ContinuationState.reset()

    try do
      {import_specs, body} = LibImport.extract_program_imports(forms)
      bindings = LibImport.resolve(import_specs, Library.standard())

      {env, syntax_env} =
        LibImport.apply_bindings(bindings, env, Expander.bootstrap_env())

      body
      |> Expander.expand_program(syntax_env)
      |> Enum.reduce(:unspecified, fn form, _acc -> Eval.eval(form, env) end)
    after
      ExceptionState.restore(prev_handlers)
      ContinuationState.restore(prev_conts)
    end
  end
end
