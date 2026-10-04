defmodule Schooner.Compiled do
  @moduledoc """
  Opaque artifact produced by `Schooner.compile/2` and consumed by
  `Schooner.run_compiled/3`.

  A `%Compiled{}` holds the **analysed core IR** of a program
  together with the **runtime variable bindings** that the program's
  `(import ...)` declarations resolved to at compile time. Macros are
  already gone — `let`, `cond`, `when`, `case`, etc. have been
  rewritten into `quote` / `if` / `lambda` / `define` /
  `define-values` / `begin` / `letrec*` / `quasiquote` / `guard` /
  application / variable references — and those core forms have been
  pre-analysed into the evaluator's tagged IR, so lambda parameter
  parsing and body desugaring are not repeated per run.

  ## Reuse semantics

  The same `%Compiled{}` can be passed to `Schooner.run_compiled/3`
  many times against many `Schooner.Environment`s, which is what
  makes it worth caching. The captured `var_bindings` are re-applied
  to the runtime env on every call; macros expanded at compile
  time stay expanded.

  Macro expansion is fixed at compile time: running the program
  against an `Environment` whose macros differ from the one passed
  to `compile` does not re-expand it. Variable bindings can differ
  freely, so host primitives can be swapped between runs. The
  program's own `(import ...)` bindings are re-applied on each run
  and shadow any same-named binding in the runtime environment.

  The IR records the source position of each application and variable
  reference, and the struct keeps the `:file` and `:debug` options
  given to `Schooner.compile/3`, so errors raised by
  `Schooner.run_compiled/3` carry the same locations as those raised by
  `Schooner.eval/3`. The artifact is still plain data. Artifacts built
  by an earlier Schooner version must be recompiled.

  ## Opacity

  Embedders must treat the struct as opaque. Pattern-matching on
  its internals is unsupported, because their shape changes with
  the evaluator's internal representation.
  """

  alias Schooner.Eval.Analyze
  alias Schooner.Library

  @enforce_keys [:program, :var_bindings]
  defstruct [:program, :var_bindings, opts: []]

  @opaque t :: %__MODULE__{
            program: [Analyze.ir()],
            var_bindings: %{binary() => Library.export()},
            opts: keyword()
          }

  @doc false
  @spec new([Analyze.ir()], %{binary() => Library.export()}, keyword()) :: t()
  def new(program, var_bindings, opts \\ [])
      when is_list(program) and is_map(var_bindings) and is_list(opts) do
    %__MODULE__{program: program, var_bindings: var_bindings, opts: opts}
  end

  @doc false
  @spec program(t()) :: [Analyze.ir()]
  def program(%__MODULE__{program: program}), do: program

  @doc false
  @spec var_bindings(t()) :: %{binary() => Library.export()}
  def var_bindings(%__MODULE__{var_bindings: var_bindings}), do: var_bindings

  @doc false
  # The `Schooner.Eval.compile/3` options the program was compiled with.
  @spec opts(t()) :: keyword()
  def opts(%__MODULE__{opts: opts}), do: opts
end
