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

  ## Diagnostics

  Errors raised by the loader quote the file path and `line:column` of
  the offending source datum where the reader can supply one. Libraries
  loaded from disk record their origin in the `:source` field as
  `{:file, path, {line, column}}`.
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
  @type ctx :: %{
          base_dir: binary() | nil,
          root_dir: binary() | nil,
          path: binary() | nil
        }

  @doc """
  Compile a single `(define-library ...)` datum against `registry`.
  Returns a `%Schooner.Library{}` ready for `Library.register/2`.

  `ctx` carries the directory used to resolve relative include paths
  and the path threaded into diagnostics.
  """
  @spec compile(Value.t(), Library.registry(), ctx()) :: Library.t()
  def compile(datum, registry, ctx \\ default_ctx()) do
    pos_tree = synthetic_pos_tree(datum)
    compile_positioned(datum, pos_tree, registry, ctx)
  end

  defp compile_positioned(
         {:pair, {:sym, "define-library"}, {:pair, name_datum, decls_list}} = datum,
         pos_tree,
         registry,
         ctx
       ) do
    name = Library.canonicalise_name(name_datum)
    decls = Value.to_list(decls_list)
    decl_positions = decl_position_trees(pos_tree)

    parts =
      decls
      |> Enum.zip(decl_positions)
      |> Enum.reduce(%{imports: [], body: [], exports: [], export_positions: [], features: []}, fn
        {decl, decl_pos}, acc ->
          apply_decl(decl, decl_pos, acc, registry, ctx)
      end)

    binding_set = LibImport.resolve(parts.imports, registry)

    {env, syntax_env} =
      LibImport.apply_bindings(binding_set, Env.new(), Expander.bootstrap_env())

    {expanded, post_syntax_env} =
      Expander.expand_program_with_env(parts.body, syntax_env)

    Enum.each(expanded, fn form -> Eval.eval(form, env) end)

    library_exports =
      build_exports(parts.exports, parts.export_positions, env, post_syntax_env, name, ctx)

    Library.new(
      name: name,
      exports: library_exports,
      imports: Enum.map(parts.imports, &spec_to_canonical_dependency/1),
      features: Enum.uniq(parts.features ++ @schooner_features),
      source: library_source(ctx, pos_tree, datum)
    )
  end

  defp compile_positioned(other, _pos_tree, _registry, _ctx) do
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
    abs_path = Path.expand(path)
    source = File.read!(abs_path)
    load_string(source, registry, base_dir: Path.dirname(abs_path), path: abs_path)
  end

  @doc """
  Compile and register every define-library form in `source`.

  Options:

    * `:base_dir` — directory used to resolve relative `(include …)` and
      `(include-library-declarations …)` paths. Defaults to `nil`,
      which makes relative includes an error.
    * `:path` — file path threaded into diagnostics. Defaults to `nil`
      (anonymous source).
  """
  @spec load_string(binary(), Library.registry(), keyword()) :: Library.registry()
  def load_string(source, registry \\ Library.standard(), opts \\ [])
      when is_binary(source) and is_list(opts) do
    base_dir =
      case Keyword.get(opts, :base_dir) do
        nil -> nil
        dir when is_binary(dir) -> Path.expand(dir)
      end

    path = Keyword.get(opts, :path)

    ctx = %{base_dir: base_dir, root_dir: base_dir, path: path}

    positioned = Reader.read_string_positioned(source)

    libs =
      Enum.map(positioned, fn
        {{:pair, {:sym, "define-library"}, _} = d, p} ->
          {d, p}

        {other, p} ->
          raise ArgumentError,
                "#{format_at(ctx, p)}expected (define-library ...), got #{inspect(other)}"
      end)

    ordered = topological_order!(libs, ctx)

    Enum.reduce(ordered, registry, fn {datum, pos_tree}, reg ->
      Library.register(reg, compile_positioned(datum, pos_tree, reg, ctx))
    end)
  end

  # ---------------------------------------------------------------------------
  # Declarations
  # ---------------------------------------------------------------------------

  defp apply_decl({:pair, {:sym, "import"}, specs}, _pos, acc, _registry, _ctx) do
    %{acc | imports: acc.imports ++ Value.to_list(specs)}
  end

  defp apply_decl({:pair, {:sym, "begin"}, forms}, _pos, acc, _registry, _ctx) do
    %{acc | body: acc.body ++ Value.to_list(forms)}
  end

  defp apply_decl({:pair, {:sym, "export"}, names}, pos_tree, acc, _registry, _ctx) do
    name_positions = export_entry_positions(pos_tree)

    %{
      acc
      | exports: acc.exports ++ Value.to_list(names),
        export_positions: acc.export_positions ++ name_positions
    }
  end

  defp apply_decl({:pair, {:sym, "cond-expand"}, clauses}, pos_tree, acc, registry, ctx) do
    clauses_list = Value.to_list(clauses)
    clause_positions = cond_expand_clause_positions(pos_tree)

    case select_cond_expand(clauses_list, clause_positions, registry, ctx) do
      {:ok, sub_decls, sub_positions} ->
        sub_decls
        |> Enum.zip(sub_positions)
        |> Enum.reduce(acc, fn {decl, p}, acc ->
          apply_decl(decl, p, acc, registry, ctx)
        end)

      :no_match ->
        acc
    end
  end

  defp apply_decl({:pair, {:sym, "include"}, paths}, pos_tree, acc, _registry, ctx) do
    path_positions = include_path_positions(pos_tree)

    forms =
      paths
      |> Value.to_list()
      |> Enum.zip(path_positions)
      |> Enum.flat_map(fn {path_datum, path_pos} ->
        path = expect_string(path_datum, "include", path_pos, ctx)
        resolved = resolve_include_path(path, ctx, path_pos)
        read_datums(resolved, path, path_pos, ctx)
      end)

    %{acc | body: acc.body ++ forms}
  end

  defp apply_decl(
         {:pair, {:sym, "include-library-declarations"}, paths},
         pos_tree,
         acc,
         registry,
         ctx
       ) do
    path_positions = include_path_positions(pos_tree)

    paths
    |> Value.to_list()
    |> Enum.zip(path_positions)
    |> Enum.reduce(acc, fn {path_datum, path_pos}, acc ->
      path = expect_string(path_datum, "include-library-declarations", path_pos, ctx)
      resolved = resolve_include_path(path, ctx, path_pos)

      {decls, decl_positions} =
        read_positioned_datums(resolved, path, path_pos, ctx)

      inner_ctx = %{ctx | base_dir: Path.dirname(resolved), path: resolved}

      decls
      |> Enum.zip(decl_positions)
      |> Enum.reduce(acc, fn {decl, p}, acc ->
        apply_decl(decl, p, acc, registry, inner_ctx)
      end)
    end)
  end

  defp apply_decl(other, pos_tree, _acc, _registry, ctx) do
    raise ArgumentError,
          "#{format_at(ctx, pos_tree)}unsupported define-library declaration: #{inspect(other)}"
  end

  # ---------------------------------------------------------------------------
  # Include path resolution
  # ---------------------------------------------------------------------------

  defp expect_string({:string, s}, _form, _pos, _ctx), do: s

  defp expect_string(other, form, pos, ctx) do
    raise ArgumentError,
          "#{format_at(ctx, pos)}(#{form} ...) expected string path, got #{inspect(other)}"
  end

  defp resolve_include_path(path, ctx, pos) do
    %{base_dir: base_dir, root_dir: root_dir} = ctx

    cond do
      Path.type(path) == :absolute ->
        check_within_root(Path.expand(path), path, root_dir, ctx, pos)

      base_dir == nil ->
        raise ArgumentError,
              "#{format_at(ctx, pos)}cannot resolve relative include path #{inspect(path)} " <>
                "without a base directory; load via Loader.load_file/2 or pass `:base_dir` " <>
                "to Loader.load_string/3"

      true ->
        check_within_root(Path.expand(path, base_dir), path, root_dir, ctx, pos)
    end
  end

  defp check_within_root(resolved, _original, nil, _ctx, _pos), do: resolved

  defp check_within_root(resolved, original, root_dir, ctx, pos) do
    if resolved == root_dir or String.starts_with?(resolved, root_dir <> "/") do
      resolved
    else
      raise ArgumentError,
            "#{format_at(ctx, pos)}include path #{inspect(original)} resolves outside the " <>
              "library root directory"
    end
  end

  defp read_datums(resolved, original, pos, ctx) do
    case File.read(resolved) do
      {:ok, source} ->
        Reader.read_string(source)

      {:error, reason} ->
        raise ArgumentError,
              "#{format_at(ctx, pos)}could not read include file #{inspect(original)}: " <>
                List.to_string(:file.format_error(reason))
    end
  end

  defp read_positioned_datums(resolved, original, pos, ctx) do
    case File.read(resolved) do
      {:ok, source} ->
        positioned = Reader.read_string_positioned(source)
        {Enum.map(positioned, &elem(&1, 0)), Enum.map(positioned, &elem(&1, 1))}

      {:error, reason} ->
        raise ArgumentError,
              "#{format_at(ctx, pos)}could not read include file #{inspect(original)}: " <>
                List.to_string(:file.format_error(reason))
    end
  end

  # ---------------------------------------------------------------------------
  # cond-expand
  # ---------------------------------------------------------------------------

  defp select_cond_expand([], [], _registry, _ctx), do: :no_match

  defp select_cond_expand(
         [{:pair, {:sym, "else"}, body} | _],
         [body_clause_pos | _],
         _registry,
         _ctx
       ) do
    {:ok, Value.to_list(body), cond_expand_body_positions(body_clause_pos)}
  end

  defp select_cond_expand(
         [{:pair, requirement, body} | rest],
         [clause_pos | rest_positions],
         registry,
         ctx
       ) do
    requirement_pos = clause_requirement_position(clause_pos)

    if requirement_satisfied?(requirement, requirement_pos, registry, ctx) do
      {:ok, Value.to_list(body), cond_expand_body_positions(clause_pos)}
    else
      select_cond_expand(rest, rest_positions, registry, ctx)
    end
  end

  defp requirement_satisfied?({:sym, name}, _pos, _registry, _ctx), do: feature_present?(name)

  defp requirement_satisfied?(
         {:pair, {:sym, "library"}, {:pair, lib_name_datum, :null}},
         _pos,
         registry,
         _ctx
       ) do
    match?({:ok, _}, Library.lookup(registry, Library.canonicalise_name(lib_name_datum)))
  end

  defp requirement_satisfied?({:pair, {:sym, "and"}, body}, pos, registry, ctx) do
    body
    |> Value.to_list()
    |> Enum.zip(combinator_argument_positions(pos))
    |> Enum.all?(fn {req, p} -> requirement_satisfied?(req, p, registry, ctx) end)
  end

  defp requirement_satisfied?({:pair, {:sym, "or"}, body}, pos, registry, ctx) do
    body
    |> Value.to_list()
    |> Enum.zip(combinator_argument_positions(pos))
    |> Enum.any?(fn {req, p} -> requirement_satisfied?(req, p, registry, ctx) end)
  end

  defp requirement_satisfied?(
         {:pair, {:sym, "not"}, {:pair, inner, :null}},
         pos,
         registry,
         ctx
       ) do
    [inner_pos] = combinator_argument_positions(pos)
    not requirement_satisfied?(inner, inner_pos, registry, ctx)
  end

  defp requirement_satisfied?(other, pos, _registry, ctx) do
    raise ArgumentError,
          "#{format_at(ctx, pos)}invalid cond-expand requirement: #{inspect(other)}"
  end

  defp feature_present?(name) do
    Enum.any?(@schooner_features, fn f -> Atom.to_string(f) == name end)
  end

  # ---------------------------------------------------------------------------
  # Exports
  # ---------------------------------------------------------------------------

  defp build_exports(export_decls, export_positions, env, syntax_env, lib_name, ctx) do
    export_decls
    |> Enum.zip(export_positions)
    |> Enum.reduce(%{}, fn {decl, decl_pos}, acc ->
      {internal, external} = parse_export_entry(decl, decl_pos, ctx)
      Map.put(acc, external, freeze_one(internal, env, syntax_env, lib_name, decl_pos, ctx))
    end)
  end

  defp parse_export_entry({:sym, name}, _pos, _ctx), do: {name, name}

  defp parse_export_entry(
         {:pair, {:sym, "rename"}, {:pair, {:sym, internal}, {:pair, {:sym, external}, :null}}},
         _pos,
         _ctx
       ) do
    {internal, external}
  end

  defp parse_export_entry(other, pos, ctx) do
    raise ArgumentError, "#{format_at(ctx, pos)}invalid export entry: #{inspect(other)}"
  end

  defp freeze_one(name, env, syntax_env, lib_name, pos, ctx) do
    case SyntaxEnv.lookup(syntax_env, name) do
      {:macro, transformer} ->
        {:macro, transformer}

      _ ->
        case Env.lookup(env, name) do
          {:ok, value} ->
            {:var, value}

          _ ->
            raise ArgumentError,
                  "#{format_at(ctx, pos)}library #{Library.render_name(lib_name)} exports " <>
                    "#{name} but no binding for it was defined"
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Topological order over file-local libraries
  # ---------------------------------------------------------------------------

  defp topological_order!(libs, ctx) do
    by_name =
      Map.new(libs, fn {datum, pos_tree} -> {extract_name(datum), {datum, pos_tree}} end)

    deps =
      Map.new(libs, fn {datum, _pos} ->
        {extract_name(datum), local_deps(datum, by_name, ctx)}
      end)

    {ordered, _done} =
      Enum.reduce(Map.keys(deps), {[], MapSet.new()}, fn name, {acc, done} ->
        visit_topo(name, deps, by_name, done, [], acc, ctx)
      end)

    Enum.map(Enum.reverse(ordered), &Map.fetch!(by_name, &1))
  end

  defp visit_topo(name, deps, by_name, done, stack, acc, ctx) do
    cond do
      MapSet.member?(done, name) ->
        {acc, done}

      name in stack ->
        cycle = Enum.reverse([name | stack])

        raise ArgumentError,
              "cycle in define-library dependencies: " <>
                Enum.map_join(cycle, " -> ", &render_cycle_entry(&1, by_name, ctx))

      true ->
        {acc, done} =
          Enum.reduce(Map.fetch!(deps, name), {acc, done}, fn dep, {acc, done} ->
            visit_topo(dep, deps, by_name, done, [name | stack], acc, ctx)
          end)

        {[name | acc], MapSet.put(done, name)}
    end
  end

  defp render_cycle_entry(name, by_name, ctx) do
    rendered = Library.render_name(name)

    case Map.fetch(by_name, name) do
      {:ok, {_datum, pos_tree}} ->
        "#{rendered} (#{format_position(ctx, pos_tree)})"

      :error ->
        rendered
    end
  end

  # ---------------------------------------------------------------------------
  # Datum / position helpers
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
      # Topological pre-pass cannot easily quote individual sub-positions
      # because positions for path datums are not threaded here; surface a
      # generic error if the path is not a string.
      path = expect_string(path_datum, "include-library-declarations", :unknown, ctx)
      resolved = resolve_include_path(path, ctx, :unknown)
      inner_ctx = %{ctx | base_dir: Path.dirname(resolved), path: resolved}

      resolved
      |> read_datums(path, :unknown, ctx)
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

  # Position-tree extractors. Each takes the position tree of a list
  # whose datum is `(head item1 item2 ...)` and returns the trees of
  # the items, skipping the head symbol.
  defp decl_position_trees(pos_tree) do
    case Reader.list_positions(pos_tree) do
      [_head, _name | decls] -> decls
      _ -> []
    end
  end

  defp export_entry_positions(pos_tree) do
    case Reader.list_positions(pos_tree) do
      [_head | entries] -> entries
      _ -> []
    end
  end

  defp include_path_positions(pos_tree) do
    case Reader.list_positions(pos_tree) do
      [_head | paths] -> paths
      _ -> []
    end
  end

  defp cond_expand_clause_positions(pos_tree) do
    case Reader.list_positions(pos_tree) do
      [_head | clauses] -> clauses
      _ -> []
    end
  end

  defp cond_expand_body_positions(clause_pos) do
    case Reader.list_positions(clause_pos) do
      [_requirement | body] -> body
      _ -> []
    end
  end

  defp clause_requirement_position(clause_pos) do
    case Reader.list_positions(clause_pos) do
      [requirement | _] -> requirement
      _ -> clause_pos
    end
  end

  defp combinator_argument_positions(pos_tree) do
    case Reader.list_positions(pos_tree) do
      [_head | args] -> args
      _ -> []
    end
  end

  # When `compile/3` is called directly with a raw datum (no reader
  # positions), synthesise a placeholder tree so the recursive walker
  # has a uniform shape. Synthesised positions render as `?:?`.
  defp synthetic_pos_tree(:null), do: {:atom, :unknown}

  defp synthetic_pos_tree({:pair, car, cdr}),
    do: {:pair, :unknown, synthetic_pos_tree(car), synthetic_pos_tree(cdr)}

  defp synthetic_pos_tree({:vector, t}) do
    items =
      0..(tuple_size(t) - 1)//1
      |> Enum.map(fn i -> synthetic_pos_tree(elem(t, i)) end)

    {:vector, :unknown, items}
  end

  defp synthetic_pos_tree(_other), do: {:atom, :unknown}

  defp default_ctx, do: %{base_dir: nil, root_dir: nil, path: nil}

  defp library_source(%{path: nil}, _pos_tree, _datum), do: :native

  defp library_source(%{path: path}, pos_tree, _datum) do
    {:file, path, position_or_unknown(pos_tree)}
  end

  defp position_or_unknown({:atom, pos}), do: pos
  defp position_or_unknown({:pair, pos, _, _}), do: pos
  defp position_or_unknown({:vector, pos, _}), do: pos
  defp position_or_unknown({:bytevector, pos}), do: pos

  # ---------------------------------------------------------------------------
  # Diagnostic formatting
  # ---------------------------------------------------------------------------

  defp format_at(ctx, pos_tree) do
    case format_position(ctx, pos_tree) do
      "" -> ""
      formatted -> "#{formatted}: "
    end
  end

  defp format_position(ctx, pos_tree) do
    {line, col} = pos_or_unknown_pair(pos_tree)
    path = ctx[:path] || ctx.path

    case {path, line, col} do
      {nil, :unknown, :unknown} -> ""
      {nil, l, c} -> "line #{l}, column #{c}"
      {p, :unknown, :unknown} -> p
      {p, l, c} -> "#{p}:#{l}:#{c}"
    end
  end

  defp pos_or_unknown_pair(:unknown), do: {:unknown, :unknown}
  defp pos_or_unknown_pair({:atom, :unknown}), do: {:unknown, :unknown}
  defp pos_or_unknown_pair({:atom, {l, c}}), do: {l, c}
  defp pos_or_unknown_pair({:pair, :unknown, _, _}), do: {:unknown, :unknown}
  defp pos_or_unknown_pair({:pair, {l, c}, _, _}), do: {l, c}
  defp pos_or_unknown_pair({:vector, :unknown, _}), do: {:unknown, :unknown}
  defp pos_or_unknown_pair({:vector, {l, c}, _}), do: {l, c}
  defp pos_or_unknown_pair({:bytevector, :unknown}), do: {:unknown, :unknown}
  defp pos_or_unknown_pair({:bytevector, {l, c}}), do: {l, c}
end
