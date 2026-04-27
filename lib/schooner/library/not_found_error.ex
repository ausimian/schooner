defmodule Schooner.Library.NotFoundError do
  @moduledoc """
  Raised when an `import` declaration (or `Schooner.Library.fetch!/2`)
  refers to a library that is not in the registry.
  """

  alias Schooner.Library

  defexception [:name]

  @impl true
  def message(%__MODULE__{name: name}) do
    "library not found: #{Library.render_name(name)}"
  end
end
