defmodule Schooner.Diagnostic do
  @moduledoc """
  A problem `Schooner.check/3` found in a script without running it.

    * `:severity` — `:error` for a problem that fails the script if
      evaluation reaches it, `:warning` for one that may not.
    * `:code` — what kind of problem it is:
        * `:read_error` — the source doesn't parse.
        * `:syntax_error` — a special form, macro use or `import` set
          is malformed.
        * `:unknown_library` — an `(import ...)` names a library the
          environment doesn't provide.
        * `:unbound` — a name isn't bound by the environment, an
          import, or a definition in the script.
        * `:arity` — a call's argument count can't match the arity of
          the procedure it calls.
    * `:message` — a description for people, without the location.
    * `:location` — the `Schooner.Location` of the problem, naming the
      file passed to `Schooner.check/3` as `:file`, or `nil` when no
      position is known.
  """

  alias Schooner.Location

  @enforce_keys [:severity, :code, :message]
  defstruct [:severity, :code, :message, :location]

  @type severity :: :error | :warning
  @type code :: :read_error | :syntax_error | :unknown_library | :unbound | :arity

  @type t :: %__MODULE__{
          severity: severity(),
          code: code(),
          message: binary(),
          location: Location.t() | nil
        }

  @doc """
  Render a diagnostic on one line, as `mix schooner.check` prints it:
  `file:line:col: severity[code]: message`.

      iex> Schooner.Diagnostic.format(%Schooner.Diagnostic{
      ...>   severity: :error,
      ...>   code: :unbound,
      ...>   message: "unbound variable: unit-prise",
      ...>   location: %Schooner.Location{file: "draft.scm", line: 1, column: 27}
      ...> })
      "draft.scm:1:27: error[unbound]: unbound variable: unit-prise"

  A location without a file renders as `line:col`; a diagnostic
  without a location starts at the severity.
  """
  @spec format(t()) :: binary()
  def format(%__MODULE__{severity: severity, code: code, message: message, location: location}) do
    prefix = if location, do: "#{location}: ", else: ""
    "#{prefix}#{severity}[#{code}]: #{message}"
  end
end
