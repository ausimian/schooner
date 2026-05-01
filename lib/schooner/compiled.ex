defmodule Schooner.Compiled do
  @moduledoc """
  Opaque artifact produced by `Schooner.compile/2` and consumed by
  `Schooner.run_compiled/2`.

  A `%Compiled{}` holds the **post-expansion core AST** of a program
  together with the **runtime variable bindings** that the program's
  `(import ...)` declarations resolved to at compile time. Macros are
  already gone from the AST — `let`, `cond`, `when`, `case`, etc.
  have been rewritten into `quote` / `if` / `lambda` / `define` /
  `define-values` / `begin` / `letrec*` / `quasiquote` / application
  / variable references.

  ## Reuse semantics

  The same `%Compiled{}` can be passed to `Schooner.run_compiled/2`
  many times against many `Schooner.Environment`s — that is the
  embedding cache win. The captured `var_bindings` are re-applied
  to the runtime env on every call; macros expanded at compile
  time stay expanded.

  Compatibility constraint: a compiled program is valid against
  any environment whose **macro environment is compatible** with
  the registry passed to `compile`. Variable sets can differ
  freely — host primitives can be swapped, and the compiled
  program's `(import ...)` bindings are baked in so they shadow
  any same-named runtime overrides. Macro additions made *after*
  compile (via a different `Environment` at run time) will not
  re-expand the program.

  ## Opacity

  Embedders must treat the struct as opaque — pattern-matching on
  internals is unsupported and reserved for evaluator changes
  (the v2.0 evaluator rewrite is the seam this opacity protects).
  """

  alias Schooner.Library
  alias Schooner.Value

  @enforce_keys [:program, :var_bindings]
  defstruct [:program, :var_bindings]

  @opaque t :: %__MODULE__{
            program: [Value.t()],
            var_bindings: %{binary() => Library.export()}
          }

  @doc false
  @spec new([Value.t()], %{binary() => Library.export()}) :: t()
  def new(program, var_bindings) when is_list(program) and is_map(var_bindings) do
    %__MODULE__{program: program, var_bindings: var_bindings}
  end

  @doc false
  @spec program(t()) :: [Value.t()]
  def program(%__MODULE__{program: program}), do: program

  @doc false
  @spec var_bindings(t()) :: %{binary() => Library.export()}
  def var_bindings(%__MODULE__{var_bindings: var_bindings}), do: var_bindings
end
