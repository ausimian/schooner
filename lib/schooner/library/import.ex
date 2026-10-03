defmodule Schooner.Library.Import do
  @moduledoc """
  Resolves r7rs `import` declarations into a flat binding set and
  applies that binding set to the runtime `Env` + expansion-time
  `SyntaxEnv`.

  An `import` declaration sits at the top of a program (or library
  body) and brings names from one or more libraries into the current
  scope. r7rs §5.2 defines four wrapping modifiers:

    * `(only spec n1 n2 ...)` — keep only the named bindings.
    * `(except spec n1 n2 ...)` — drop the named bindings.
    * `(prefix spec p)` — prepend `p` to every bound name.
    * `(rename spec (old1 new1) (old2 new2) ...)` — rename specific
      bindings simultaneously, so swaps and rotations preserve the original values.

  Modifiers compose: `(prefix (only (scheme base) car cdr) my-)`.

  Resolution is purely against a `Schooner.Library` registry that the
  caller passes in (typically `Schooner.Library.standard/0`).
  Missing libraries raise `Schooner.Library.NotFoundError` with the
  canonical name of the offender. Names inside `only`, `except`, or
  `rename` (the old name) must be exported by the inner spec after
  its modifiers are applied. Unknown names raise `Schooner.Eval.Error`
  with reason `{:unknown_import_identifier, modifier, identifier, library_name}`,
  where the modifier and identifier are strings and the library name
  is canonical.

  Rename destinations must be unique and must not overwrite an export
  that remains under its original name. A destination renamed away in
  the same import set is allowed. Collisions raise `Schooner.Eval.Error`
  with reason `{:duplicate_import_identifier, "rename", new, library_name}`
  or `{:import_identifier_collision, "rename", old, new, library_name}`.
  """

  alias Schooner.Env
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Library
  alias Schooner.Value

  @type binding :: Library.export()
  @type binding_set :: %{binary() => binding()}

  @doc """
  Walk the leading forms of a program, separating `(import ...)`
  declarations from the rest. r7rs requires imports to precede every
  other top-level form in a program, so extraction stops at the first
  non-import form; any later `(import ...)` is left in the body.

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
    inner_exports = resolve_one(inner, registry)
    validate_names!(inner_exports, names, "only", inner)
    Map.take(inner_exports, names)
  end

  # (except spec n1 n2 ...)
  defp resolve_one([{:sym, "except"} | [inner | name_list]], registry) do
    names = name_list |> Value.to_list() |> Enum.map(&sym_name!/1)
    inner_exports = resolve_one(inner, registry)
    validate_names!(inner_exports, names, "except", inner)
    Map.drop(inner_exports, names)
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
    old_names = Enum.map(renames, &elem(&1, 0))
    validate_names!(inner_exports, old_names, "rename", inner)

    retained_exports = Map.drop(inner_exports, old_names)
    validate_rename_destinations!(renames, retained_exports, inner)
    renamed_exports = Map.new(renames, fn {old, new} -> {new, Map.fetch!(inner_exports, old)} end)
    Map.merge(retained_exports, renamed_exports)
  end

  # Bare library name like (scheme base) or (srfi 1).
  defp resolve_one([_ | _] = name_datum, registry) do
    Library.fetch!(registry, Library.canonicalise_name(name_datum)).exports
  end

  defp resolve_one(other, _registry) do
    raise ArgumentError, "invalid import spec: #{inspect(other)}"
  end

  defp validate_names!(exports, names, modifier, inner) do
    Enum.each(names, fn name ->
      unless Map.has_key?(exports, name) do
        raise EvalError,
          reason: {:unknown_import_identifier, modifier, name, import_library_name(inner)}
      end
    end)
  end

  defp validate_rename_destinations!(renames, retained_exports, inner) do
    Enum.reduce(renames, MapSet.new(), fn {old, new}, destinations ->
      if MapSet.member?(destinations, new) do
        raise EvalError,
          reason: {:duplicate_import_identifier, "rename", new, import_library_name(inner)}
      end

      if Map.has_key?(retained_exports, new) do
        raise EvalError,
          reason: {:import_identifier_collision, "rename", old, new, import_library_name(inner)}
      end

      MapSet.put(destinations, new)
    end)
  end

  defp import_library_name([{:sym, modifier}, inner | _])
       when modifier in ["only", "except", "prefix", "rename"] do
    import_library_name(inner)
  end

  defp import_library_name(name_datum), do: Library.canonicalise_name(name_datum)

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
