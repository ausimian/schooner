defmodule Schooner.Expander.Derived do
  @moduledoc """
  Source loader for the bootstrap macros shipped with Schooner.

  Reads the `.scm` files under `priv/scheme/` and concatenates them
  into a single source binary that
  `Schooner.Expander.bootstrap_env/0` parses and expands once per VM:

    * `base.scm` — derived forms (`when`, `unless`, `and`, `or`, `let`,
      `let*`, `letrec`, `cond`, `case`, `do`, `let-values`,
      `let*-values`, `parameterize`).
    * `lazy.scm` — `delay` and `delay-force`.

  ## Quasiquote

  `quasiquote` remains a core form handled by the evaluator
  (`Schooner.Eval.Analyze`) rather than a `syntax-rules` macro. r7rs
  §4.2.8 defines it recursively, tracking the quasiquote level and
  covering vector templates; that level tracking is awkward to express
  in `syntax-rules`.
  """

  alias Schooner.Library.Scheme

  @priv_files ["base.scm", "lazy.scm"]

  @doc """
  Concatenated bootstrap source: every `.scm` file in `@priv_files`
  joined with `\\n` between them. Used by
  `Schooner.Expander.bootstrap_env/0`.
  """
  @spec source() :: binary()
  def source, do: Enum.map_join(@priv_files, "\n", &Scheme.read/1)

  @doc "Files contributing to the bootstrap env source, in load order."
  @spec priv_files() :: [binary()]
  def priv_files, do: @priv_files
end
