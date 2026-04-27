defmodule Schooner.Library.Standard do
  @moduledoc """
  Builds the registry of standard r7rs libraries shipped with Schooner
  and persists it under the canonical key for cheap, copy-free lookup
  from any process.

  Phase 13.1 lands the boot skeleton with no actual libraries yet —
  later phases populate `(scheme base)`, `(scheme cxr)`, `(scheme
  char)`, `(scheme inexact)`, `(scheme write)`, `(scheme read)`,
  `(scheme case-lambda)`, and `(scheme lazy)` into the registry the
  skeleton produces.

  Idempotent: calling `boot/0` repeatedly rebuilds and re-persists the
  same registry. The first call from `Schooner.Application.start/2` is
  the single-flight that avoids the global literal-area GC that
  re-`put`ting persistent terms triggers; later calls accept that
  cost.
  """

  alias Schooner.Library

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
  def build_registry, do: %{}
end
