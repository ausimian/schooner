defmodule Schooner.Library.Standard do
  @moduledoc """
  Builds the registry of standard r7rs libraries shipped with Schooner
  and persists it under the canonical key for cheap, copy-free lookup
  from any process.

  `(scheme base)` is assembled from the union of `Primitives.Base`,
  `Primitives.Record`, `Primitives.Exceptions`,
  `Primitives.Continuations`, plus the `newline` and `write-string`
  output primitives in `Primitives.Write.base_io_specs/0`, plus the
  syntax-rules macros defined in `priv/scheme/base.scm` (`when`,
  `unless`, `and`, `or`, `let`, `let*`, `letrec`, `cond`, `case`,
  `do`). The other libraries map one-to-one to a single primitive
  module:

    * `(scheme cxr)` → `Primitives.Cxr`
    * `(scheme char)` → `Primitives.Char`
    * `(scheme inexact)` → `Primitives.Inexact`
    * `(scheme write)` → `Primitives.Write`
    * `(scheme read)` → `Primitives.Read`
    * `(scheme lazy)` → `Primitives.Lazy` plus the `delay` and
      `delay-force` macros from `priv/scheme/lazy.scm`.

  `(scheme case-lambda)` exposes the `case-lambda` macro defined in
  `priv/scheme/case-lambda.scm`, which lowers to a chain of plain
  `lambda`s wrapped in a rest-only outer lambda that dispatches by
  arity at call time.

  Idempotent: calling `boot/0` repeatedly rebuilds and re-persists the
  same registry. The first call from `Schooner.Application.start/2` is
  the single-flight that avoids the global literal-area GC that
  re-`put`ting persistent terms triggers; later calls accept that
  cost.
  """

  alias Schooner.Expander
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Library
  alias Schooner.Library.Scheme
  alias Schooner.Primitives
  alias Schooner.Reader
  alias Schooner.Value

  @doc """
  Build the standard registry and store it in persistent term storage.
  Called once at OTP application start.
  """
  @spec boot() :: :ok
  def boot, do: Library.persist!(build_registry())

  @doc """
  Build the standard registry without touching persistent term
  storage. Useful for tests that want to exercise the registry shape
  without disturbing the global persistent-term key.
  """
  @spec build_registry() :: Library.registry()
  def build_registry do
    %{}
    |> Library.register(scheme_base())
    |> Library.register(scheme_cxr())
    |> Library.register(scheme_char())
    |> Library.register(scheme_inexact())
    |> Library.register(scheme_write())
    |> Library.register(scheme_read())
    |> Library.register(scheme_case_lambda())
    |> Library.register(scheme_lazy())
  end

  defp scheme_base do
    Library.new(
      name: ["scheme", "base"],
      exports:
        Map.merge(
          exports_from_specs([
            Primitives.Base.specs(),
            Primitives.Record.specs(),
            Primitives.Exceptions.specs(),
            Primitives.Continuations.specs(),
            Primitives.Write.base_io_specs()
          ]),
          macros_from_priv("base.scm")
        ),
      features: [:r7rs]
    )
  end

  defp scheme_cxr do
    Library.new(
      name: ["scheme", "cxr"],
      exports: exports_from_specs([Primitives.Cxr.specs()]),
      features: [:r7rs]
    )
  end

  defp scheme_char do
    Library.new(
      name: ["scheme", "char"],
      exports: exports_from_specs([Primitives.Char.specs()]),
      features: [:r7rs]
    )
  end

  defp scheme_inexact do
    Library.new(
      name: ["scheme", "inexact"],
      exports: exports_from_specs([Primitives.Inexact.specs()]),
      features: [:r7rs]
    )
  end

  defp scheme_write do
    Library.new(
      name: ["scheme", "write"],
      exports: exports_from_specs([Primitives.Write.specs()]),
      features: [:r7rs]
    )
  end

  defp scheme_read do
    Library.new(
      name: ["scheme", "read"],
      exports: exports_from_specs([Primitives.Read.specs()]),
      features: [:r7rs]
    )
  end

  defp scheme_case_lambda do
    Library.new(
      name: ["scheme", "case-lambda"],
      exports: macros_from_priv("case-lambda.scm"),
      features: [:r7rs]
    )
  end

  defp scheme_lazy do
    Library.new(
      name: ["scheme", "lazy"],
      exports:
        Map.merge(
          exports_from_specs([Primitives.Lazy.specs()]),
          macros_from_priv("lazy.scm")
        ),
      features: [:r7rs]
    )
  end

  defp exports_from_specs(spec_lists) do
    spec_lists
    |> List.flatten()
    |> Map.new(fn {name, arity, fun} ->
      {name, {:var, Value.primitive(name, arity, fun)}}
    end)
  end

  defp macros_from_priv(filename) do
    forms =
      filename
      |> Scheme.read()
      |> Reader.read_string()

    {_expanded, env} = Expander.expand_program_with_env(forms, SyntaxEnv.new())

    for {name, {:macro, _} = binding} <- env.globals, into: %{} do
      {name, binding}
    end
  end
end
