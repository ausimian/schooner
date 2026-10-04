defmodule Schooner.Library.NotFoundError do
  @moduledoc """
  Raised when an `import` declaration (or `Schooner.Library.fetch!/2`)
  refers to a library that is not in the registry. `:location` is the
  `Schooner.Location` of the `import` form, when it is known.
  """

  alias Schooner.Library
  alias Schooner.Location

  defexception [:name, :location]

  @impl true
  def message(%__MODULE__{name: name, location: location}) do
    Location.prefix(location) <> "library not found: #{Library.render_name(name)}"
  end

  @doc false
  def put_location(%__MODULE__{} = e, location), do: %{e | location: location}
end
