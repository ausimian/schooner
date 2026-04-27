defmodule Schooner.Error do
  @moduledoc """
  Host-side exception raised when a Scheme `raise` / `raise-continuable`
  / `error` is not caught by any installed `with-exception-handler` or
  `guard`. The struct carries the original Scheme value verbatim so the
  host can inspect it; for the common case of an error object the
  `:message` and `:irritants` fields are pre-extracted to make
  pattern-matching from Elixir straightforward.

  This is distinct from `Schooner.Eval.Error` and
  `Schooner.Primitive.Error`, which signal evaluator/primitive failures
  that the host gets directly without crossing the Scheme exception
  machinery. Phase 11 only routes explicit `raise` calls through here;
  evaluator/primitive errors continue to propagate as before.
  """

  alias Schooner.Value

  defexception [:value, :message, :irritants]

  @impl true
  def exception(opts) do
    value = Keyword.fetch!(opts, :value)

    irritants =
      case value do
        {:error_obj, _kind, _msg, irrs} -> irrs
        _ -> []
      end

    %__MODULE__{value: value, message: format(value), irritants: irritants}
  end

  defp format({:error_obj, _kind, message, irritants}) do
    msg_text =
      case message do
        {:string, s} -> s
        other -> Value.write(other)
      end

    case irritants do
      [] ->
        "uncaught Scheme error: #{msg_text}"

      list ->
        rendered = list |> Enum.map(&Value.write/1) |> Enum.intersperse(" ")
        IO.iodata_to_binary(["uncaught Scheme error: ", msg_text, ": ", rendered])
    end
  end

  defp format(other), do: "uncaught Scheme raise: #{Value.write(other)}"
end
