defmodule Schooner.Eval.Error do
  @moduledoc """
  Exception raised by the evaluator for runtime and syntactic failures.

  The `:reason` field is a structured term — atom or tagged tuple — meant
  to be matched on. The `:message` is derived from the reason, so
  assertions can pin behaviour on `:reason` without coupling to wording.

  `:location` is the `Schooner.Location` of the form that failed, or
  `nil` when it is not known. See "Source locations" in `Schooner`.
  With `debug: true`, `:scheme_backtrace` lists the procedure calls
  that led to the error, most recent first (see `Schooner.Frame`);
  otherwise it is `nil`.
  """

  alias Schooner.Location

  defexception [:reason, :message, :location, :scheme_backtrace]

  @impl true
  def exception(opts) do
    reason = Keyword.fetch!(opts, :reason)
    location = Keyword.get(opts, :location)

    %__MODULE__{
      reason: reason,
      location: location,
      message: Location.prefix(location) <> format(reason)
    }
  end

  defp format({:unknown_import_identifier, modifier, name, library}) do
    "import modifier `#{modifier}`: identifier `#{name}` is not exported by the inner " <>
      "import set for library #{Schooner.Library.render_name(library)}"
  end

  defp format({:duplicate_import_identifier, modifier, name, library}) do
    "import modifier `#{modifier}`: multiple clauses target identifier `#{name}` " <>
      "in the import set for library #{Schooner.Library.render_name(library)}"
  end

  defp format({:import_identifier_collision, modifier, old, new, library}) do
    "import modifier `#{modifier}`: renaming identifier `#{old}` to `#{new}` would overwrite " <>
      "an export retained by the inner import set for library #{Schooner.Library.render_name(library)}"
  end

  defp format({:unbound, name}), do: "unbound variable: #{name}"
  defp format(:empty_application), do: "() is not a valid expression"
  defp format({:not_a_procedure, value}), do: "not a procedure: #{inspect(value)}"
  defp format({:bad_special_form, name}), do: "malformed `#{name}` form"
  defp format(:invalid_params), do: "invalid lambda parameter list"
  defp format(:improper_application), do: "improper application form"
  defp format(:define_after_expression), do: "internal `define` after a non-definition expression"
  defp format(:empty_body), do: "body must contain at least one expression"

  defp format(:nested_define_syntax_unsupported) do
    "`define-syntax` is only supported at top level; " <>
      "use `let-syntax` or `letrec-syntax` for local macros"
  end

  defp format(:continuation_expired) do
    "continuation invoked after its dynamic extent has ended " <>
      "(Schooner continuations are escape-only)"
  end

  defp format({:rec_uninitialised, name}) do
    "letrec binding `#{name}` referenced before its init has been evaluated"
  end

  defp format({:arity_mismatch, name, {:exact, expected}, got}) do
    "arity mismatch in #{name_str(name)}: expected #{expected}, got #{got}"
  end

  defp format({:arity_mismatch, name, {:at_least, expected}, got}) do
    "arity mismatch in #{name_str(name)}: expected at least #{expected}, got #{got}"
  end

  defp format({:arity_mismatch, name, {:at_most, expected}, got}) do
    "arity mismatch in #{name_str(name)}: expected at most #{expected}, got #{got}"
  end

  defp format({:arity_mismatch, name, {:between, lo, hi}, got}) do
    "arity mismatch in #{name_str(name)}: expected between #{lo} and #{hi}, got #{got}"
  end

  defp name_str(nil), do: "anonymous procedure"
  defp name_str(name) when is_binary(name), do: "`#{name}`"
end
