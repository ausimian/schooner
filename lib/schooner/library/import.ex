defmodule Schooner.Library.Import do
  @moduledoc """
  Resolves r7rs `import` declarations into a flat binding set and
  applies that binding set to the runtime `Env` + expansion-time
  `SyntaxEnv`.

  An `import` declaration sits at the top of a program (or library
  body) and brings names from one or more libraries into the current
  scope. r7rs §5.6.1 defines four wrapping modifiers:

    * `(only spec n1 n2 ...)` — keep only the named bindings.
    * `(except spec n1 n2 ...)` — drop the named bindings.
    * `(prefix spec p)` — prepend `p` to every bound name.
    * `(rename spec (old1 new1) (old2 new2) ...)` — rename specific
      bindings.

  Modifiers compose: `(prefix (only (scheme base) car cdr) my-)`.

  Resolution is purely against `Schooner.Library`'s registry — the
  caller passes the registry in (typically `Schooner.Library.standard/0`).
  Missing libraries raise `Schooner.Library.NotFoundError` with the
  canonical name of the offender; missing names inside `only` or
  `rename` are skipped silently to match r7rs's "ignore-not-present"
  rule for `rename` and surface an error for `only` (the latter is
  caught at the call site for clearer reporting).
  """

  alias Schooner.Env
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Library
  alias Schooner.Value

  @type binding :: Library.export()
  @type binding_set :: %{binary() => binding()}

  @doc """
  Walk the leading forms of a program, separating `(import ...)`
  declarations from the rest. r7rs requires imports to precede every
  other top-level form in a program — once a non-import form is
  encountered, no later `(import ...)` is accepted.

  Returns `{import_specs, body_forms}` where `import_specs` is the
  flat list of every spec datum across all leading `(import ...)`
  declarations.
  """
  @spec extract_program_imports([Value.t()]) ::
          {[Value.t()], [Value.t()]}
  def extract_program_imports(forms) do
    do_extract([], forms)
  end

  defp do_extract(acc, [[{:sym, "import"} | tail] | rest]) do
    do_extract([Value.to_list(tail) | acc], rest)
  end

  defp do_extract(acc, rest) do
    {acc |> Enum.reverse() |> Enum.concat(), rest}
  end

  @doc """
  Resolve a list of import-spec datums against `registry`, returning a
  flat binding set keyed by the *imported* (post-modifier) name.
  Earlier specs are merged with later ones; collisions resolve in
  favour of the later spec, matching r7rs's "later imports shadow
  earlier" rule.
  """
  @spec resolve([Value.t()], Library.registry()) :: binding_set()
  def resolve(specs, registry) do
    Enum.reduce(specs, %{}, fn spec, acc ->
      Map.merge(acc, resolve_one(spec, registry))
    end)
  end

  # (only spec n1 n2 ...)
  defp resolve_one([{:sym, "only"} | [inner | name_list]], registry) do
    names = name_list |> Value.to_list() |> Enum.map(&sym_name!/1)
    Map.take(resolve_one(inner, registry), names)
  end

  # (except spec n1 n2 ...)
  defp resolve_one([{:sym, "except"} | [inner | name_list]], registry) do
    names = name_list |> Value.to_list() |> Enum.map(&sym_name!/1)
    Map.drop(resolve_one(inner, registry), names)
  end

  # (prefix spec p)
  defp resolve_one(
         [{:sym, "prefix"} | [inner | [{:sym, prefix} | []]]],
         registry
       ) do
    inner_exports = resolve_one(inner, registry)
    Map.new(inner_exports, fn {name, v} -> {prefix <> name, v} end)
  end

  # (rename spec (old new) ...)
  defp resolve_one([{:sym, "rename"} | [inner | rename_list]], registry) do
    renames = parse_renames(rename_list)
    inner_exports = resolve_one(inner, registry)

    Enum.reduce(renames, inner_exports, fn {old, new}, exports ->
      case Map.fetch(exports, old) do
        {:ok, v} -> exports |> Map.delete(old) |> Map.put(new, v)
        :error -> exports
      end
    end)
  end

  # Bare library name like (scheme base) or (srfi 1).
  defp resolve_one([_ | _] = name_datum, registry) do
    Library.fetch!(registry, Library.canonicalise_name(name_datum)).exports
  end

  defp resolve_one(other, _registry) do
    raise ArgumentError, "invalid import spec: #{inspect(other)}"
  end

  defp parse_renames([]), do: []

  defp parse_renames([[{:sym, old} | [{:sym, new} | []]] | rest]) do
    [{old, new} | parse_renames(rest)]
  end

  defp parse_renames(other) do
    raise ArgumentError, "invalid rename clause: #{inspect(other)}"
  end

  defp sym_name!({:sym, name}), do: name

  defp sym_name!(other) do
    raise ArgumentError,
          "import modifier name must be a symbol, got #{inspect(other)}"
  end

  @doc """
  Apply `bindings` to `env` (variables) and `syntax_env` (macros).
  Returns the augmented pair. Variable values are written via
  `Env.define/3`; macro transformers via `SyntaxEnv.define_macro/3`.
  """
  @spec apply_bindings(binding_set(), Env.t(), SyntaxEnv.t()) :: {Env.t(), SyntaxEnv.t()}
  def apply_bindings(bindings, %Env{} = env, %SyntaxEnv{} = syntax_env) do
    Enum.reduce(bindings, {env, syntax_env}, fn
      {name, {:var, value}}, {e, se} ->
        {Env.define(e, name, value), se}

      {name, {:macro, transformer}}, {e, se} ->
        {e, SyntaxEnv.define_macro(se, name, transformer)}
    end)
  end
end
