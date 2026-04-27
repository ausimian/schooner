defmodule Schooner.Expander.Derived do
  @moduledoc """
  Source loader for the bootstrap macros shipped with Schooner.

  Reads the `.scm` files under `priv/scheme/` and concatenates them
  into a single source binary that
  `Schooner.Expander.bootstrap_env/0` parses and expands once per VM.
  Two files contribute today:

    * `base.scm` — derived forms (when, unless, and, or, let, let*,
      letrec, cond, case, do).
    * `lazy.scm` — `delay` and `delay-force`.

  ## Quasiquote

  `quasiquote` stays as a special form in `Schooner.Eval` rather than
  becoming a `syntax-rules` macro. r7rs §4.2.8 lays out a recursive,
  level-aware definition that includes vector quasiquotation; that
  level tracking is awkward to express with finite, non-recursive
  `syntax-rules` rules, and the existing evaluator implementation is
  the simpler home.
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
