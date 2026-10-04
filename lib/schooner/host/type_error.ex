defmodule Schooner.Host.TypeError do
  @moduledoc """
  Raised by `Schooner.Host` asserting accessors (`to_*!/2`) when a
  Scheme value does not match the shape the host expected.

  The exception carries `:op` (a host-supplied label naming the call
  site, e.g. `"my-lib/info"`), `:expected` (a short description of the
  shape that was demanded, e.g. `"string"`, `"proper list"`), and
  `:got` (the actual value, rendered with `inspect/1` in the
  message). Callers can match on `:op` and `:expected` without
  depending on the message wording.

  `:location` is the `Schooner.Location` of the script call that
  reached the host function. It is only filled in when the script runs
  with `debug: true`; see "Source locations" in `Schooner`. With
  `debug: true`, `:scheme_backtrace` lists the procedure calls that
  led to the error, most recent first (see `Schooner.Frame`); otherwise
  it is `nil`.
  """

  alias Schooner.Location

  defexception [:op, :expected, :got, :message, :location, :scheme_backtrace]

  @type t :: %__MODULE__{
          op: binary(),
          expected: binary(),
          got: term(),
          message: binary(),
          location: Location.t() | nil,
          scheme_backtrace: [Schooner.Frame.t()] | nil
        }

  @impl true
  def exception(opts) do
    op = Keyword.fetch!(opts, :op)
    expected = Keyword.fetch!(opts, :expected)
    got = Keyword.fetch!(opts, :got)

    %__MODULE__{
      op: op,
      expected: expected,
      got: got,
      message: format(op, expected, got)
    }
  end

  defp format(op, expected, got) do
    "host conversion in `#{op}`: expected #{expected}, got #{inspect(got)}"
  end
end
