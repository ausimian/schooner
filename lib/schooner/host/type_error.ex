defmodule Schooner.Host.TypeError do
  @moduledoc """
  Raised by `Schooner.Host` asserting accessors (`to_*!/2`) when a
  Scheme value does not match the shape the host expected.

  The exception carries `:op` (a host-supplied label naming the call
  site, e.g. `"my-lib/info"`), `:expected` (a short description of the
  shape that was demanded, e.g. `"string"`, `"proper list"`), and
  `:got` (the actual value, rendered with `inspect/1` in the
  message). Tests can pattern on `:op` and `:expected` without
  coupling to wording.
  """

  defexception [:op, :expected, :got, :message]

  @type t :: %__MODULE__{
          op: binary(),
          expected: binary(),
          got: term(),
          message: binary()
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
