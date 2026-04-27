defmodule Schooner.Application do
  @moduledoc false

  # Schooner's OTP application callback. Its only job is to populate
  # `Schooner.Expander.bootstrap_env/0`'s `:persistent_term` cache
  # eagerly, so that:
  #
  #   1. The first `Schooner.eval/2` call on the node does not pay the
  #      bootstrap parse-and-expand cost, and
  #
  #   2. Concurrent first-evals cannot race the lazy `get → build →
  #      put` path. The lazy path stores the env only if the key is
  #      `:unset`, but two callers can observe `:unset` simultaneously,
  #      both build (each minting fresh `make_ref/0` hygiene marks),
  #      and both `put`. The second `put` is then an *update* of an
  #      existing key, and `:persistent_term.put/2` triggers a global
  #      literal-area GC across all processes when it replaces a
  #      value. Eager init from `start/2` is a single-flight by
  #      construction.
  #
  # `bootstrap_env/0` itself retains the lazy path for callers that
  # use the library without starting the application (some test
  # scenarios, embedding-by-direct-module-call); under normal
  # operation that branch is dead.

  use Application

  @impl Application
  def start(_type, _args) do
    _ = Schooner.Expander.bootstrap_env()
    Supervisor.start_link([], strategy: :one_for_one, name: Schooner.Supervisor)
  end
end
