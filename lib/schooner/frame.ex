defmodule Schooner.Frame do
  @moduledoc """
  One entry in the Scheme backtrace of an error raised with
  `debug: true`: a procedure application the script made.

    * `:name` — the procedure's name: the name it was defined with, the
      name of a primitive, `"<lambda>"` for an anonymous procedure, or
      `"<parameter>"` for a parameter object.
    * `:location` — the `Schooner.Location` of the call, or `nil` when
      it is not known.
    * `:tail?` — `true` when the call was in tail position. The
      procedure that made it had already finished, so the frame below
      it in the backtrace is the one it replaced, not a caller waiting
      for it to return.

  Exceptions carry their frames in `:scheme_backtrace`, most recent
  first. See "Backtraces" in the tooling guide.
  """

  alias Schooner.Location

  @enforce_keys [:name, :location, :tail?]
  defstruct [:name, :location, :tail?]

  @type t :: %__MODULE__{name: binary(), location: Location.t() | nil, tail?: boolean()}
end
