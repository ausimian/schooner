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

  This module exposes the convenience entry points used by tests and by
  early embeddings. The full embedding API arrives in a later phase.
  """

  alias Schooner.Env
  alias Schooner.Eval
  alias Schooner.Expander
  alias Schooner.Primitives
  alias Schooner.Reader
  alias Schooner.Value

  @doc """
  An environment preloaded with the standard primitives shipped by
  Schooner. `Env.new/0` deliberately stays empty for tests that want
  isolation; this is the entry point for callers that want a usable
  Scheme out of the box.
  """
  @spec standard_env() :: Env.t()
  def standard_env do
    Env.new()
    |> Primitives.Base.register_into()
    |> Primitives.Cxr.register_into()
    |> Primitives.Char.register_into()
    |> Primitives.Record.register_into()
  end

  @doc """
  Read and evaluate `source` in a fresh standard environment. Returns
  the value of the last datum, or `:unspecified` for empty input.
  """
  @spec run(binary()) :: Value.t()
  def run(source) when is_binary(source), do: eval(source, standard_env())

  @doc """
  Read and evaluate `source` in the given environment, threading
  top-level definitions into it. Returns the value of the last datum.
  """
  @spec eval(binary(), Env.t()) :: Value.t()
  def eval(source, %Env{} = env) when is_binary(source) do
    source
    |> Reader.read_string()
    |> Expander.expand_program(Expander.bootstrap_env())
    |> Enum.reduce(:unspecified, fn form, _acc -> Eval.eval(form, env) end)
  end
end
