defmodule Schooner.Library.Loader do
  @moduledoc """
  Compiles `(define-library ...)` declarations into
  `%Schooner.Library{}` registry entries.

  ## Supported declaration heads

    * `(import spec ...)` — pull bindings from already-registered
      libraries. Composes with all of the modifiers handled by
      `Schooner.Library.Import`.
    * `(begin form ...)` — body forms evaluated in the library's
      private env.
    * `(export name ...)` — names visible to importers. Each entry is
      a bare symbol or `(rename internal external)`. Names not bound
      by the body or imports raise at compile time.
    * `(cond-expand clause ...)` — selects a list of declarations
      based on the feature requirement clauses. Supported requirement
      forms: `feature-id` (a symbol), `(library NAME)`, `(and ...)`,
      `(or ...)`, `(not ...)`, and an `else` clause.

  ## Deferred

  `(include "path")` and `(include-library-declarations "path")` are
  deferred to a later phase; the path-resolution logic is mostly
  identical to `(include)` once the loader carries source-relative
  context. Source-position threading for diagnostics is also a
  follow-up.
  """

  alias Schooner.Env
  alias Schooner.Eval
  alias Schooner.Expander
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Library
  alias Schooner.Library.Import, as: LibImport
  alias Schooner.Reader
  alias Schooner.Value

  @schooner_features [:r7rs]

  @doc """
  Compile a single `(define-library ...)` datum against `registry`.
  Returns a `%Schooner.Library{}` ready for `Library.register/2`.
  """
  @spec compile(Value.t(), Library.registry()) :: Library.t()
  def compile(
        {:pair, {:sym, "define-library"}, {:pair, name_datum, decls_list}},
        registry
      ) do
    name = canonical_name(name_datum)
    decls = list_to_elixir_list(decls_list)

    parts =
      Enum.reduce(decls, %{imports: [], body: [], exports: [], features: []}, fn decl, acc ->
        apply_decl(decl, acc, registry)
      end)

    binding_set = LibImport.resolve(parts.imports, registry)

    {env, syntax_env} =
      LibImport.apply_bindings(binding_set, Env.new(), Expander.bootstrap_env())

    {expanded, post_syntax_env} =
      Expander.expand_program_with_env(parts.body, syntax_env)

    Enum.each(expanded, fn form -> Eval.eval(form, env) end)

    library_exports = build_exports(parts.exports, env, post_syntax_env, name)

    Library.new(
      name: name,
      exports: library_exports,
      imports: Enum.map(parts.imports, &spec_to_canonical_dependency/1),
      features: Enum.uniq(parts.features ++ @schooner_features)
    )
  end

  def compile(other, _registry) do
    raise ArgumentError, "expected a (define-library ...) datum, got #{inspect(other)}"
  end

  @doc """
  Read a file containing one or more `(define-library ...)` forms and
  register every library it defines into `registry`. Libraries are
  compiled in topological order so each library's dependencies are
  already present when its body is evaluated. Returns the augmented
  registry.

  Raises `ArgumentError` on cycles in the local-to-the-file dependency
  graph. Cycles that mix file-local libraries with already-registered
  libraries cannot occur because the registry is append-only.
  """
  @spec load_file(binary(), Library.registry()) :: Library.registry()
  def load_file(path, registry \\ Library.standard()) when is_binary(path) do
    path
    |> File.read!()
    |> load_string(registry)
  end

  @doc "Compile and register every define-library form in `source`."
  @spec load_string(binary(), Library.registry()) :: Library.registry()
  def load_string(source, registry \\ Library.standard()) when is_binary(source) do
    datums = Reader.read_string(source)

    libs =
      Enum.map(datums, fn
        {:pair, {:sym, "define-library"}, _} = d -> d
        other -> raise ArgumentError, "expected (define-library ...), got #{inspect(other)}"
      end)

    ordered = topological_order!(libs)

    Enum.reduce(ordered, registry, fn datum, reg -> Library.register(reg, compile(datum, reg)) end)
  end

  # ---------------------------------------------------------------------------
  # Declarations
  # ---------------------------------------------------------------------------

  defp apply_decl({:pair, {:sym, "import"}, specs}, acc, _registry) do
    %{acc | imports: acc.imports ++ list_to_elixir_list(specs)}
  end

  defp apply_decl({:pair, {:sym, "begin"}, forms}, acc, _registry) do
    %{acc | body: acc.body ++ list_to_elixir_list(forms)}
  end

  defp apply_decl({:pair, {:sym, "export"}, names}, acc, _registry) do
    %{acc | exports: acc.exports ++ list_to_elixir_list(names)}
  end

  defp apply_decl({:pair, {:sym, "cond-expand"}, clauses}, acc, registry) do
    case select_cond_expand(list_to_elixir_list(clauses), registry) do
      {:ok, sub_decls} ->
        Enum.reduce(sub_decls, acc, &apply_decl(&1, &2, registry))

      :no_match ->
        acc
    end
  end

  defp apply_decl({:pair, {:sym, "include"}, _}, _acc, _registry) do
    raise ArgumentError, "(include ...) is not yet supported in define-library bodies"
  end

  defp apply_decl(
         {:pair, {:sym, "include-library-declarations"}, _},
         _acc,
         _registry
       ) do
    raise ArgumentError,
          "(include-library-declarations ...) is not yet supported in define-library bodies"
  end

  defp apply_decl(other, _acc, _registry) do
    raise ArgumentError, "unsupported define-library declaration: #{inspect(other)}"
  end

  # ---------------------------------------------------------------------------
  # cond-expand
  # ---------------------------------------------------------------------------

  defp select_cond_expand([], _registry), do: :no_match

  defp select_cond_expand(
         [{:pair, {:sym, "else"}, body} | _],
         _registry
       ) do
    {:ok, list_to_elixir_list(body)}
  end

  defp select_cond_expand([{:pair, requirement, body} | rest], registry) do
    if requirement_satisfied?(requirement, registry) do
      {:ok, list_to_elixir_list(body)}
    else
      select_cond_expand(rest, registry)
    end
  end

  defp requirement_satisfied?({:sym, name}, _registry), do: feature_present?(name)

  defp requirement_satisfied?(
         {:pair, {:sym, "library"}, {:pair, lib_name_datum, :null}},
         registry
       ) do
    name = canonical_name(lib_name_datum)
    match?({:ok, _}, Library.lookup(registry, name))
  end

  defp requirement_satisfied?({:pair, {:sym, "and"}, body}, registry) do
    body
    |> list_to_elixir_list()
    |> Enum.all?(&requirement_satisfied?(&1, registry))
  end

  defp requirement_satisfied?({:pair, {:sym, "or"}, body}, registry) do
    body
    |> list_to_elixir_list()
    |> Enum.any?(&requirement_satisfied?(&1, registry))
  end

  defp requirement_satisfied?({:pair, {:sym, "not"}, {:pair, inner, :null}}, registry) do
    not requirement_satisfied?(inner, registry)
  end

  defp requirement_satisfied?(other, _registry) do
    raise ArgumentError, "invalid cond-expand requirement: #{inspect(other)}"
  end

  defp feature_present?(name) do
    Enum.any?(@schooner_features, fn f -> Atom.to_string(f) == name end)
  end

  # ---------------------------------------------------------------------------
  # Exports
  # ---------------------------------------------------------------------------

  defp build_exports(export_decls, env, syntax_env, lib_name) do
    Enum.reduce(export_decls, %{}, fn decl, acc ->
      {internal, external} = parse_export_entry(decl)
      Map.put(acc, external, freeze_one(internal, env, syntax_env, lib_name))
    end)
  end

  defp parse_export_entry({:sym, name}), do: {name, name}

  defp parse_export_entry(
         {:pair, {:sym, "rename"}, {:pair, {:sym, internal}, {:pair, {:sym, external}, :null}}}
       ) do
    {internal, external}
  end

  defp parse_export_entry(other) do
    raise ArgumentError, "invalid export entry: #{inspect(other)}"
  end

  defp freeze_one(name, env, syntax_env, lib_name) do
    case SyntaxEnv.lookup(syntax_env, name) do
      {:macro, transformer} ->
        {:macro, transformer}

      _ ->
        case Env.lookup(env, name) do
          {:ok, value} ->
            {:var, value}

          _ ->
            raise ArgumentError,
                  "library #{Library.render_name(lib_name)} exports #{name} but no binding for it was defined"
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Topological order over file-local libraries
  # ---------------------------------------------------------------------------

  defp topological_order!(datums) do
    by_name = Map.new(datums, fn d -> {extract_name(d), d} end)
    deps = Map.new(datums, fn d -> {extract_name(d), local_deps(d, by_name)} end)

    {ordered, _done} =
      Enum.reduce(Map.keys(deps), {[], MapSet.new()}, fn name, {acc, done} ->
        visit_topo(name, deps, done, [], acc)
      end)

    Enum.map(Enum.reverse(ordered), &Map.fetch!(by_name, &1))
  end

  defp visit_topo(name, deps, done, stack, acc) do
    cond do
      MapSet.member?(done, name) ->
        {acc, done}

      name in stack ->
        raise ArgumentError,
              "cycle in define-library dependencies: " <>
                Enum.map_join(Enum.reverse([name | stack]), " -> ", &Library.render_name/1)

      true ->
        {acc, done} =
          Enum.reduce(Map.fetch!(deps, name), {acc, done}, fn dep, {acc, done} ->
            visit_topo(dep, deps, done, [name | stack], acc)
          end)

        {[name | acc], MapSet.put(done, name)}
    end
  end

  # ---------------------------------------------------------------------------
  # Datum helpers
  # ---------------------------------------------------------------------------

  defp extract_name({:pair, {:sym, "define-library"}, {:pair, name_datum, _}}) do
    canonical_name(name_datum)
  end

  defp local_deps({:pair, {:sym, "define-library"}, {:pair, _, decls}}, by_name) do
    decls
    |> list_to_elixir_list()
    |> Enum.flat_map(&decl_imports/1)
    |> Enum.map(&spec_to_canonical_dependency/1)
    |> Enum.filter(&Map.has_key?(by_name, &1))
  end

  defp decl_imports({:pair, {:sym, "import"}, specs}), do: list_to_elixir_list(specs)
  defp decl_imports(_), do: []

  # Reduce an import spec to the canonical name of the library it
  # ultimately points at, ignoring any wrapping modifiers.
  defp spec_to_canonical_dependency({:pair, {:sym, head}, {:pair, inner, _rest}})
       when head in ["only", "except", "prefix", "rename"] do
    spec_to_canonical_dependency(inner)
  end

  defp spec_to_canonical_dependency(name_datum), do: canonical_name(name_datum)

  defp canonical_name(datum) do
    datum
    |> list_to_elixir_list()
    |> Enum.map(&segment_to_canonical!/1)
  end

  defp segment_to_canonical!({:sym, name}), do: name
  defp segment_to_canonical!(int) when is_integer(int) and int >= 0, do: int

  defp segment_to_canonical!(other) do
    raise ArgumentError,
          "library name segments must be symbols or non-negative integers, got #{inspect(other)}"
  end

  defp list_to_elixir_list(:null), do: []
  defp list_to_elixir_list({:pair, h, t}), do: [h | list_to_elixir_list(t)]

  defp list_to_elixir_list(other),
    do: raise(ArgumentError, "expected proper list, got #{inspect(other)}")
end
