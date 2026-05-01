defmodule Schooner.Time do
  @moduledoc """
  The r7rs `(scheme time)` library, supplied as a host library.

  This module is a worked example of an *embeddable* Schooner library
  — an Elixir module that builds a `t:Schooner.Library.t/0` via
  `Schooner.Host.library/1`. The library is **not** in Schooner's
  default standard registry; embedders opt in by listing it on
  `Schooner.Environment.new/1`:

      env =
        Schooner.Environment.new(
          libraries: [Schooner.Time.library()]
        )

      Schooner.eval!(\"(import (scheme time)) (current-second)\", env)
      # => 1745234567.123456

  The name `(scheme time)` is the canonical r7rs name; scripts opt in
  the spec-conformant way with `(import (scheme time))`. Because the
  library is not pre-registered, an embedder who does not list it
  preserves the "default sandbox is pure" property — wall-clock
  access has to be deliberately granted.

  ## Why a host library, not a baked-in primitive

  Every primitive Schooner ships in `(scheme base)`, `(scheme inexact)`,
  and friends is pure and deterministic. Time is the first
  side-effecting binding: it leaks wall-clock state into the script
  and breaks reproducibility. Keeping it out of the default registry
  and shipping it as a separately-opt-in host library matches the
  trust model documented in [Sandbox](sandbox.md).

  Authoring this as a host library — instead of as one more
  `Schooner.Primitives.*` module — also makes it a worked reference
  for embedders writing their own libraries. The shape here is the
  shape recommended in [Host Functions](host-functions.md):

    1. A single public `library/0` (or `library/1` if the host needs
       to inject configuration) that returns a `%Schooner.Library{}`.
    2. Internal primitive implementations follow the standard
       `(list(Schooner.Value.t()) -> Schooner.Value.t())` ABI.
    3. The library name is canonical (`["scheme", "time"]` here),
       which makes it sandbox-safe — the script must
       `(import ...)` to reach it.

  Copy this file as a starting point for any embeddable library that
  needs to expose host capabilities to Scheme.

  ## Procedures

  All three procedures are r7rs §6.13:

    * `(current-second)` — inexact seconds since the epoch. Backed by
      `:os.system_time(:nanosecond) / 1.0e9`. R7RS specifies TAI
      seconds; Schooner returns POSIX seconds, matching what every
      mainstream Scheme implementation actually does (Chibi, Racket,
      Guile).

    * `(current-jiffy)` — exact monotonic integer. Backed by
      `:erlang.monotonic_time/0`. The absolute value is unspecified
      and may be negative; only differences between two `current-jiffy`
      calls in the same VM are meaningful.

    * `(jiffies-per-second)` — exact integer giving the resolution of
      `current-jiffy`. Backed by
      `:erlang.convert_time_unit(1, :second, :native)`. Expected
      idiom: divide a jiffy difference by this to get seconds.
  """

  alias Schooner.Host
  alias Schooner.Library

  @doc """
  Build the `(scheme time)` host library. Pass to
  `Schooner.Environment.new/1` to make `(import (scheme time))`
  reachable from scripts evaluated against the environment.
  """
  @spec library() :: Library.t()
  def library do
    Host.library(name: ["scheme", "time"], primitives: specs())
  end

  @doc """
  Primitive specs in the `{name, arity, fun}` shape used everywhere
  in the Schooner primitive layer. Exposed so an embedder can fold
  these into a larger custom library if they need a non-canonical
  name or want to combine time with other host primitives.
  """
  @spec specs() :: [{binary(), 0, ([] -> Schooner.Value.t())}]
  def specs do
    [
      {"current-second", 0, &current_second/1},
      {"current-jiffy", 0, &current_jiffy/1},
      {"jiffies-per-second", 0, &jiffies_per_second/1}
    ]
  end

  defp current_second([]), do: :os.system_time(:nanosecond) / 1.0e9
  defp current_jiffy([]), do: :erlang.monotonic_time()
  defp jiffies_per_second([]), do: :erlang.convert_time_unit(1, :second, :native)
end
