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
    * `(include "path" ...)` — read each named file as a sequence of
      body forms and splice them into the library's `(begin …)`. Paths
      resolve relative to the file containing the `include` form.
    * `(include-library-declarations "path" ...)` — read each named
      file as a sequence of declarations and process them in place.
      Paths resolve relative to the including file, so nested includes
      thread the directory of the innermost file.

  Relative include paths that resolve outside the entry-point's
  directory are rejected; absolute paths are likewise rejected unless
  they fall inside the entry-point's directory.
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

  @typedoc "Path-resolution context threaded through declaration processing."
  @type ctx :: %{base_dir: binary() | nil, root_dir: binary() | nil}

  @doc """
  Compile a single `(define-library ...)` datum against `registry`.
  Returns a `%Schooner.Library{}` ready for `Library.register/2`.

  `ctx` carries the directory used to resolve relative include paths.
  """
  @spec compile(Value.t(), Library.registry(), ctx()) :: Library.t()
  def compile(datum, registry, ctx \\ %{base_dir: nil, root_dir: nil})

  def compile(
        {:pair, {:sym, "define-library"}, {:pair, name_datum, decls_list}},
        registry,
        ctx
      ) do
    name = Library.canonicalise_name(name_datum)
    decls = Value.to_list(decls_list)

    parts =
      Enum.reduce(decls, %{imports: [], body: [], exports: [], features: []}, fn decl, acc ->
        apply_decl(decl, acc, registry, ctx)
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

  def compile(other, _registry, _ctx) do
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
    source = File.read!(path)
    load_string(source, registry, base_dir: Path.dirname(Path.expand(path)))
  end

  @doc """
  Compile and register every define-library form in `source`.

  Options:

    * `:base_dir` — directory used to resolve relative `(include …)` and
      `(include-library-declarations …)` paths. Defaults to `nil`,
      which makes relative includes an error.
  """
  @spec load_string(binary(), Library.registry(), keyword()) :: Library.registry()
  def load_string(source, registry \\ Library.standard(), opts \\ [])
      when is_binary(source) and is_list(opts) do
    base_dir =
      case Keyword.get(opts, :base_dir) do
        nil -> nil
        dir when is_binary(dir) -> Path.expand(dir)
      end

    ctx = %{base_dir: base_dir, root_dir: base_dir}

    datums = Reader.read_string(source)

    libs =
      Enum.map(datums, fn
        {:pair, {:sym, "define-library"}, _} = d -> d
        other -> raise ArgumentError, "expected (define-library ...), got #{inspect(other)}"
      end)

    ordered = topological_order!(libs, ctx)

    Enum.reduce(ordered, registry, fn datum, reg ->
      Library.register(reg, compile(datum, reg, ctx))
    end)
  end

  # ---------------------------------------------------------------------------
  # Declarations
  # ---------------------------------------------------------------------------

  defp apply_decl({:pair, {:sym, "import"}, specs}, acc, _registry, _ctx) do
    %{acc | imports: acc.imports ++ Value.to_list(specs)}
  end

  defp apply_decl({:pair, {:sym, "begin"}, forms}, acc, _registry, _ctx) do
    %{acc | body: acc.body ++ Value.to_list(forms)}
  end

  defp apply_decl({:pair, {:sym, "export"}, names}, acc, _registry, _ctx) do
    %{acc | exports: acc.exports ++ Value.to_list(names)}
  end

  defp apply_decl({:pair, {:sym, "cond-expand"}, clauses}, acc, registry, ctx) do
    case select_cond_expand(Value.to_list(clauses), registry) do
      {:ok, sub_decls} ->
        Enum.reduce(sub_decls, acc, &apply_decl(&1, &2, registry, ctx))

      :no_match ->
        acc
    end
  end

  defp apply_decl({:pair, {:sym, "include"}, paths}, acc, _registry, ctx) do
    forms =
      paths
      |> Value.to_list()
      |> Enum.flat_map(fn path_datum ->
        path = expect_string(path_datum, "include")
        resolved = resolve_include_path(path, ctx)
        read_datums(resolved, path)
      end)

    %{acc | body: acc.body ++ forms}
  end

  defp apply_decl(
         {:pair, {:sym, "include-library-declarations"}, paths},
         acc,
         registry,
         ctx
       ) do
    paths
    |> Value.to_list()
    |> Enum.reduce(acc, fn path_datum, acc ->
      path = expect_string(path_datum, "include-library-declarations")
      resolved = resolve_include_path(path, ctx)
      decls = read_datums(resolved, path)
      inner_ctx = %{ctx | base_dir: Path.dirname(resolved)}
      Enum.reduce(decls, acc, &apply_decl(&1, &2, registry, inner_ctx))
    end)
  end

  defp apply_decl(other, _acc, _registry, _ctx) do
    raise ArgumentError, "unsupported define-library declaration: #{inspect(other)}"
  end

  # ---------------------------------------------------------------------------
  # Include path resolution
  # ---------------------------------------------------------------------------

  defp expect_string({:string, s}, _form), do: s

  defp expect_string(other, form) do
    raise ArgumentError, "(#{form} ...) expected string path, got #{inspect(other)}"
  end

  defp resolve_include_path(path, %{base_dir: base_dir, root_dir: root_dir}) do
    cond do
      Path.type(path) == :absolute ->
        check_within_root(Path.expand(path), path, root_dir)

      base_dir == nil ->
        raise ArgumentError,
              "cannot resolve relative include path #{inspect(path)} without a base directory; " <>
                "load via Loader.load_file/2 or pass `:base_dir` to Loader.load_string/3"

      true ->
        check_within_root(Path.expand(path, base_dir), path, root_dir)
    end
  end

  defp check_within_root(resolved, _original, nil), do: resolved

  defp check_within_root(resolved, original, root_dir) do
    if resolved == root_dir or String.starts_with?(resolved, root_dir <> "/") do
      resolved
    else
      raise ArgumentError,
            "include path #{inspect(original)} resolves outside the library root directory"
    end
  end

  defp read_datums(resolved, original) do
    case File.read(resolved) do
      {:ok, source} ->
        Reader.read_string(source)

      {:error, reason} ->
        raise ArgumentError,
              "could not read include file #{inspect(original)}: #{:file.format_error(reason)}"
    end
  end

  # ---------------------------------------------------------------------------
  # cond-expand
  # ---------------------------------------------------------------------------

  defp select_cond_expand([], _registry), do: :no_match

  defp select_cond_expand(
         [{:pair, {:sym, "else"}, body} | _],
         _registry
       ) do
    {:ok, Value.to_list(body)}
  end

  defp select_cond_expand([{:pair, requirement, body} | rest], registry) do
    if requirement_satisfied?(requirement, registry) do
      {:ok, Value.to_list(body)}
    else
      select_cond_expand(rest, registry)
    end
  end

  defp requirement_satisfied?({:sym, name}, _registry), do: feature_present?(name)

  defp requirement_satisfied?(
         {:pair, {:sym, "library"}, {:pair, lib_name_datum, :null}},
         registry
       ) do
    match?({:ok, _}, Library.lookup(registry, Library.canonicalise_name(lib_name_datum)))
  end

  defp requirement_satisfied?({:pair, {:sym, "and"}, body}, registry) do
    body
    |> Value.to_list()
    |> Enum.all?(&requirement_satisfied?(&1, registry))
  end

  defp requirement_satisfied?({:pair, {:sym, "or"}, body}, registry) do
    body
    |> Value.to_list()
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

  defp topological_order!(datums, ctx) do
    by_name = Map.new(datums, fn d -> {extract_name(d), d} end)
    deps = Map.new(datums, fn d -> {extract_name(d), local_deps(d, by_name, ctx)} end)

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
    Library.canonicalise_name(name_datum)
  end

  defp local_deps({:pair, {:sym, "define-library"}, {:pair, _, decls}}, by_name, ctx) do
    decls
    |> Value.to_list()
    |> Enum.flat_map(&decl_imports(&1, ctx))
    |> Enum.map(&spec_to_canonical_dependency/1)
    |> Enum.filter(&Map.has_key?(by_name, &1))
  end

  defp decl_imports({:pair, {:sym, "import"}, specs}, _ctx), do: Value.to_list(specs)

  defp decl_imports({:pair, {:sym, "include-library-declarations"}, paths}, ctx) do
    paths
    |> Value.to_list()
    |> Enum.flat_map(fn path_datum ->
      path = expect_string(path_datum, "include-library-declarations")
      resolved = resolve_include_path(path, ctx)
      inner_ctx = %{ctx | base_dir: Path.dirname(resolved)}

      resolved
      |> read_datums(path)
      |> Enum.flat_map(&decl_imports(&1, inner_ctx))
    end)
  end

  defp decl_imports(_other, _ctx), do: []

  # Reduce an import spec to the canonical name of the library it
  # ultimately points at, ignoring any wrapping modifiers.
  defp spec_to_canonical_dependency({:pair, {:sym, head}, {:pair, inner, _rest}})
       when head in ["only", "except", "prefix", "rename"] do
    spec_to_canonical_dependency(inner)
  end

  defp spec_to_canonical_dependency(name_datum), do: Library.canonicalise_name(name_datum)
end
