defmodule Schooner.Error do
  @moduledoc """
  Host-side exception raised when a Scheme `raise` / `raise-continuable`
  / `error` is not caught by any installed `with-exception-handler` or
  `guard`. The struct carries the original Scheme value verbatim in
  `:value`; for an error object the host can pattern-match
  `{:error_obj, kind, message, irritants}` directly, or use
  `irritants/1` for the common case.

  This is distinct from `Schooner.Eval.Error` and
  `Schooner.Primitive.Error`, which signal evaluator and primitive
  failures. Those reach the host directly without passing through
  the Scheme exception handlers. Values raised from Scheme or through
  `Schooner.Host.raise_error/2` and `Schooner.Host.raise_value/1` end up
  here when unhandled. Host code should use those helpers for errors
  scripts can catch; raising `Schooner.Error` directly bypasses Scheme
  handlers.
  """

  alias Schooner.Value

  @type t :: %__MODULE__{value: Value.t(), message: binary() | nil}

  defexception [:value, :message]

  @impl true
  def exception(opts) do
    value = Keyword.fetch!(opts, :value)
    %__MODULE__{value: value, message: format(value)}
  end

  @doc """
  Return the irritants of `error`'s wrapped value when it is an error
  object; `[]` for any other raised value.
  """
  @spec irritants(t()) :: [Value.t()]
  def irritants(%__MODULE__{value: {:error_obj, _, _, irrs}}), do: irrs
  def irritants(%__MODULE__{}), do: []

  defp format({:error_obj, _kind, message, irritants}) do
    msg_text =
      case message do
        s when is_binary(s) -> s
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
