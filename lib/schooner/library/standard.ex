defmodule Schooner.Library.Standard do
  @moduledoc """
  Builds the registry of standard r7rs libraries shipped with Schooner
  and persists it under the canonical key for cheap, copy-free lookup
  from any process.

  `(scheme base)` is assembled from the union of `Primitives.Base`,
  `Primitives.Record`, `Primitives.Exceptions`, and
  `Primitives.Continuations` — every binding in those modules is in
  r7rs §6 / §7's `(scheme base)` library. The other libraries map
  one-to-one to a single primitive module:
  `(scheme cxr)` → `Primitives.Cxr`, `(scheme char)` →
  `Primitives.Char`, `(scheme inexact)` → `Primitives.Inexact`,
  `(scheme write)` → `Primitives.Write`, `(scheme read)` →
  `Primitives.Read`.

  `(scheme case-lambda)` and `(scheme lazy)` are registered with
  empty exports here; their macros land in 13.3 from
  `priv/scheme/*.scm`.

  Idempotent: calling `boot/0` repeatedly rebuilds and re-persists the
  same registry. The first call from `Schooner.Application.start/2` is
  the single-flight that avoids the global literal-area GC that
  re-`put`ting persistent terms triggers; later calls accept that
  cost.
  """

  alias Schooner.Library
  alias Schooner.Primitives
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
        exports_from_specs([
          Primitives.Base.specs(),
          Primitives.Record.specs(),
          Primitives.Exceptions.specs(),
          Primitives.Continuations.specs()
        ]),
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
    # Exports populated in 13.3 from priv/scheme/case-lambda.scm.
    Library.new(name: ["scheme", "case-lambda"], features: [:r7rs])
  end

  defp scheme_lazy do
    # Exports populated in 13.3 from priv/scheme/lazy.scm.
    Library.new(name: ["scheme", "lazy"], features: [:r7rs])
  end

  defp exports_from_specs(spec_lists) do
    spec_lists
    |> List.flatten()
    |> Map.new(fn {name, arity, fun} ->
      {name, {:var, Value.primitive(name, arity, fun)}}
    end)
  end
end
