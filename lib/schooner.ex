defmodule Schooner do
  @moduledoc """
  An embeddable, sandboxed Scheme interpreter for the BEAM, targeting the
  r7rs-small language minus its mutable operations.

  This module re-exports the public embedding API. The interpreter itself
  is built up across `Schooner.Value`, `Schooner.Lexer`, `Schooner.Reader`,
  `Schooner.Expander`, `Schooner.Env`, and `Schooner.Eval`.
  """
end
