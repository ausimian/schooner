defmodule Schooner do
  @moduledoc """
  An embeddable, sandboxed Scheme interpreter for the BEAM, targeting the
  r7rs-small language minus its mutable operations.

  The pipeline is `Schooner.Lexer` → `Schooner.Reader` → `Schooner.Eval`,
  with `Schooner.Value` providing the tagged-term value model and
  `Schooner.Env` the immutable-with-mutable-globals environment.

  This module exposes the convenience entry points used by tests and by
  early embeddings. The full embedding API arrives in a later phase.
  """

  alias Schooner.Env
  alias Schooner.Eval
  alias Schooner.Reader
  alias Schooner.Value

  @doc """
  Read and evaluate `source` in a fresh environment. Returns the value
  of the last datum, or `:unspecified` for empty input.
  """
  @spec run(binary()) :: Value.t()
  def run(source) when is_binary(source), do: eval(source, Env.new())

  @doc """
  Read and evaluate `source` in the given environment, threading
  top-level definitions into it. Returns the value of the last datum.
  """
  @spec eval(binary(), Env.t()) :: Value.t()
  def eval(source, %Env{} = env) when is_binary(source) do
    source
    |> Reader.read_string()
    |> Enum.reduce(:unspecified, fn form, _acc -> Eval.eval(form, env) end)
  end
end
