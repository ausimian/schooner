defmodule Schooner.Library.Scheme do
  @moduledoc """
  Helpers for reading the `.scm` sources shipped under `priv/scheme/`.

  Centralised so that both `Schooner.Expander.Derived` (which composes
  the bootstrap env's macro source) and `Schooner.Library.Standard`
  (which extracts per-file macro sets to attach to library exports)
  resolve paths the same way.
  """

  @doc "Read a single `priv/scheme/<filename>` as a binary."
  @spec read(binary()) :: binary()
  def read(filename) when is_binary(filename) do
    :schooner
    |> :code.priv_dir()
    |> Path.join(["scheme/", filename])
    |> File.read!()
  end
end
