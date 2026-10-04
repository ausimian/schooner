defmodule Schooner.Checker do
  @moduledoc false

  # The static checker behind `Schooner.check/3`.
  #
  # A script is read with positions, its imports are resolved, and each
  # top-level form is expanded and analysed as `Schooner.eval/3` would,
  # but nothing is evaluated. The checker then walks the analysed IR
  # (see `Schooner.Eval.Analyze`):
  #
  #   * every `{:raise, exception}` node, and every `{:bad, exception}`
  #     `guard` clause, is a malformed form;
  #   * every `{:gref, ...}` must name a global the environment defines,
  #     an import binds, or the script defines somewhere;
  #   * a call through a `gref` whose procedure is known must have an
  #     argument count the procedure accepts.
  #
  # Lexical references were resolved to slots by analysis, so they
  # need no checking, and a lexical binding shadows a global of the
  # same name without any work here.
  #
  # ## Staying quiet when unsure
  #
  # A diagnostic must never fire on a script that runs, so the checker
  # errs towards silence:
  #
  #   * A script definition counts wherever it appears, not only before
  #     the reference.
  #   * A name the script defines more than once, with anything but a
  #     `lambda`, or over a binding from the environment or an import
  #     (directly, or through the base of a macro-marked name), has an
  #     unknown arity, and calls to it go unchecked.
  #   * When an import fails, its names are unknown, so no `:unbound`
  #     diagnostics are reported at all.
  #   * When a top-level form fails to expand or analyse, the names it
  #     would have defined are taken from its shape (see
  #     `declared_names/1`) and count as defined.

  alias Schooner.Diagnostic
  alias Schooner.Env
  alias Schooner.Environment
  alias Schooner.Eval.Analyze
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Expander
  alias Schooner.Expander.Error, as: ExpanderError
  alias Schooner.Expander.Positions, as: Pos
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Expander.SyntaxRules
  alias Schooner.Lexer
  alias Schooner.Library.Import, as: LibImport
  alias Schooner.Library.NotFoundError
  alias Schooner.Location
  alias Schooner.Reader

  @spec check(binary(), Environment.t(), keyword()) :: [Diagnostic.t()]
  def check(source, %Environment{} = environment, opts) do
    file = Keyword.get(opts, :file)

    case read(source) do
      {:ok, forms} -> check_forms(forms, environment, file)
      {:error, e} -> [diagnostic(:read_error, e, file)]
    end
  end

  defp read(source) do
    {:ok, Reader.read_string_positioned(source)}
  rescue
    e in [Lexer.Error, Reader.Error] -> {:error, e}
  end

  defp check_forms(forms, environment, file) do
    {specs, body, extract_diags} = extract_imports(forms, file)
    {bindings, import_diags} = resolve_imports(specs, Environment.registry(environment), file)

    syntax_env =
      Enum.reduce(bindings, Environment.syntax_env(environment), fn
        {name, {:macro, transformer}}, se -> SyntaxEnv.define_macro(se, name, transformer)
        _, se -> se
      end)

    {irs, declared, expand_diags} = expand(body, syntax_env, file)

    imported = for {name, {:var, value}} <- bindings, into: %{}, do: {name, value_arity(value)}

    bound =
      environment
      |> Environment.env()
      |> Env.globals()
      |> Map.new(fn {name, value} -> {name, value_arity(value)} end)
      |> Map.merge(imported)

    # A call can reach a name's existing binding until the script's own
    # definition of it runs, so a name defined over an existing binding
    # has no single arity. Nor does a marked name a macro defines whose
    # base name is bound: a marked reference falls back to the base
    # until the definition runs.
    definitions = definitions(irs)

    defined =
      Map.new(definitions, fn {name, arity} ->
        replaces? =
          Map.has_key?(bound, name) or
            case SyntaxRules.strip_mark(name) do
              {:ok, base} -> Map.has_key?(bound, base) or Map.has_key?(definitions, base)
              :error -> false
            end

        {name, if(replaces?, do: :unknown, else: arity)}
      end)

    known =
      bound
      |> Map.merge(Map.new(declared, &{&1, :unknown}))
      |> Map.merge(defined)

    cx = %{
      file: file,
      known: known,
      unbound?: extract_diags == [] and import_diags == []
    }

    walk_diags = irs |> Enum.reduce([], &walk(&1, cx, &2)) |> Enum.reverse()

    Enum.sort_by(extract_diags ++ import_diags ++ expand_diags ++ walk_diags, &sort_key/1)
  end

  defp sort_key(%Diagnostic{location: nil}), do: {0, 0}
  defp sort_key(%Diagnostic{location: %Location{line: line, column: column}}), do: {line, column}

  # ---------------------------------------------------------------------------
  # Imports
  # ---------------------------------------------------------------------------

  # The leading `(import ...)` forms as `{spec, tree}` pairs, the rest
  # of the program, and a diagnostic for each `import` form that is not
  # a proper list.
  defp extract_imports(forms, file), do: extract_imports(forms, file, [], [])

  defp extract_imports([{[{:sym, "import"} | specs], tree} | rest], file, pairs, diags) do
    case proper_elements(specs, Pos.cdr(tree)) do
      {:ok, new_pairs} ->
        extract_imports(rest, file, Enum.reverse(new_pairs, pairs), diags)

      :error ->
        diag = syntax_diagnostic({:bad_special_form, "import"}, Pos.at(tree), file)
        extract_imports(rest, file, pairs, [diag | diags])
    end
  end

  defp extract_imports(rest, _file, pairs, diags),
    do: {Enum.reverse(pairs), rest, Enum.reverse(diags)}

  defp proper_elements([], _t), do: {:ok, []}

  defp proper_elements([h | rest], t) do
    with {:ok, more} <- proper_elements(rest, Pos.cdr(t)), do: {:ok, [{h, Pos.car(t)} | more]}
  end

  defp proper_elements(_, _t), do: :error

  # Resolve each spec on its own, so a failure is placed at the spec
  # that caused it and the others still bind their names. Later specs
  # shadow earlier ones, as in `Schooner.Library.Import.resolve/2`.
  defp resolve_imports(spec_pairs, registry, file) do
    {bindings, diags} =
      Enum.reduce(spec_pairs, {%{}, []}, fn {spec, tree}, {bindings, diags} ->
        case resolve_import(spec, registry) do
          {:ok, more} ->
            {Map.merge(bindings, more), diags}

          {:error, code, e} ->
            e = Location.attach(e, Location.new(nil, Pos.at(tree)))
            {bindings, [diagnostic(code, e, file) | diags]}
        end
      end)

    {bindings, Enum.reverse(diags)}
  end

  defp resolve_import(spec, registry) do
    {:ok, LibImport.resolve([spec], registry)}
  rescue
    e in NotFoundError ->
      {:error, :unknown_library, e}

    e in EvalError ->
      case e.reason do
        {:unknown_import_identifier, _, _, _} -> {:error, :unbound, e}
        _ -> {:error, :syntax_error, e}
      end

    # A malformed import set (a non-symbol in `only`, a bad `rename`
    # clause, a spec that is not a list).
    ArgumentError ->
      {:error, :syntax_error, EvalError.exception(reason: {:bad_special_form, "import"})}
  end

  # ---------------------------------------------------------------------------
  # Expansion and analysis
  # ---------------------------------------------------------------------------

  # Expand and analyse the body one top-level form at a time, so that a
  # form that fails to expand is reported and the rest are still
  # checked. Returns the IR of every form that expanded, the names
  # declared by the forms that did not, and their diagnostics.
  defp expand(body, syntax_env, file) do
    {irs, declared, diags, _syntax_env} =
      Enum.reduce(body, {[], [], [], syntax_env}, fn form, {irs, declared, diags, se} ->
        case expand_form(form, se) do
          {:ok, new_irs, names, se} ->
            {Enum.reverse(new_irs, irs), names ++ declared, diags, se}

          {:error, e} ->
            {form_datum, _tree} = form

            {irs, declared_names(form_datum) ++ declared,
             [diagnostic(:syntax_error, e, file) | diags], se}
        end
      end)

    {Enum.reverse(irs), declared, Enum.reverse(diags)}
  end

  # Analysis replaces a malformed definition with a `{:raise, _}` node,
  # so the names of expanded forms are declared too. A definition that
  # analysis keeps overrides its declaration.
  defp expand_form(form, syntax_env) do
    {expanded, syntax_env} = Expander.expand_positioned([form], syntax_env)
    irs = Enum.map(expanded, fn {f, t} -> Analyze.analyze(f, t) end)
    names = Enum.flat_map(expanded, fn {f, _t} -> declared_names(f) end)
    {:ok, irs, names, syntax_env}
  rescue
    e in [EvalError, ExpanderError] -> {:error, e}
  end

  # The names a top-level form would define, read from its shape, so
  # that a form that fails to expand or analyse doesn't make later
  # references to those names unbound.
  defp declared_names([{:sym, "define"}, {:sym, name} | _]), do: [name]
  defp declared_names([{:sym, "define"}, [{:sym, name} | _] | _]), do: [name]
  defp declared_names([{:sym, "define-syntax"}, {:sym, name} | _]), do: [name]
  defp declared_names([{:sym, "define-values"}, formals | _]), do: symbols(formals)
  defp declared_names([{:sym, "define-record-type"} | spec]), do: symbols(spec)

  defp declared_names([{:sym, "begin"} | forms]) when is_list(forms),
    do: forms |> proper_prefix() |> Enum.flat_map(&declared_names/1)

  defp declared_names(_), do: []

  defp symbols({:sym, name}), do: [name]
  defp symbols([h | t]), do: symbols(h) ++ symbols(t)
  defp symbols(_), do: []

  defp proper_prefix([h | t]), do: [h | proper_prefix(t)]
  defp proper_prefix(_), do: []

  # The arity of every name the script defines: the `lambda`'s arity
  # for a name defined once as a procedure, `:unknown` otherwise.
  defp definitions(irs) do
    irs
    |> Enum.reduce([], &collect_definitions/2)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn
      {name, [arity]} -> {name, arity}
      {name, _} -> {name, :unknown}
    end)
  end

  defp collect_definitions({:define, name, expr}, acc),
    do: collect_definitions(expr, [{name, expr_arity(expr)} | acc])

  defp collect_definitions({:define_values, params, expr}, acc) do
    names = params |> params_names() |> Enum.map(&{&1, :unknown})
    collect_definitions(expr, names ++ acc)
  end

  # Quoted data can hold anything, including improper lists.
  defp collect_definitions({tag, _datum}, acc) when tag in [:const, :qc], do: acc

  defp collect_definitions(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect_definitions(acc)

  defp collect_definitions([h | t], acc), do: collect_definitions(t, collect_definitions(h, acc))
  defp collect_definitions(_, acc), do: acc

  defp params_names({:fixed, _, names}), do: names
  defp params_names({:any, name}), do: [name]
  defp params_names({:fixed_rest, _, names, rest}), do: names ++ [rest]

  defp expr_arity({:lambda, params, _body, _name}), do: params_arity(params)
  defp expr_arity(_), do: :unknown

  defp value_arity({:primitive, _name, arity, _fun}), do: arity
  defp value_arity({:closure, params, _body, _env, _name}), do: params_arity(params)
  defp value_arity(_), do: :unknown

  defp params_arity({:fixed, n, _}), do: n
  defp params_arity({:any, _}), do: {:at_least, 0}
  defp params_arity({:fixed_rest, n, _, _}), do: {:at_least, n}

  # ---------------------------------------------------------------------------
  # The IR walk
  # ---------------------------------------------------------------------------

  defp walk_all(irs, cx, acc), do: Enum.reduce(irs, acc, &walk(&1, cx, &2))

  defp walk({:const, _}, _cx, acc), do: acc
  defp walk({:lref, _, _}, _cx, acc), do: acc

  # A `rref`'s fallback is only consulted once its frame has been
  # released, and the frame binds the name, so it is never unbound.
  defp walk({:rref, _, _, _, _, _}, _cx, acc), do: acc

  defp walk({:gref, name, _marked, pos} = ref, cx, acc) do
    if cx.unbound? and not bound?(ref, cx) do
      reason = {:unbound, display_name(name)}
      [diagnostic(:unbound, EvalError.exception(reason: reason), cx.file, pos) | acc]
    else
      acc
    end
  end

  defp walk({:raise, e}, cx, acc), do: [diagnostic(:syntax_error, e, cx.file) | acc]
  defp walk({:if, test, then_e, else_e}, cx, acc), do: walk_all([test, then_e, else_e], cx, acc)

  defp walk({:app, head, args, _pos} = app, cx, acc) do
    acc = walk_all([head | args], cx, acc)
    check_arity(app, cx, acc)
  end

  defp walk({:lambda, _params, {_names, body}, _name}, cx, acc), do: walk_all(body, cx, acc)
  defp walk({:define, _name, expr}, cx, acc), do: walk(expr, cx, acc)
  defp walk({:define_values, _params, expr}, cx, acc), do: walk(expr, cx, acc)
  defp walk({:seq, body}, cx, acc), do: walk_all(body, cx, acc)

  defp walk({tag, _names, bindings, body}, cx, acc) when tag in [:letrec, :letseq] do
    acc =
      Enum.reduce(bindings, acc, fn
        {:single, _slot, init}, acc -> walk(init, cx, acc)
        {:multi, _params, init, _slots}, acc -> walk(init, cx, acc)
      end)

    walk_all(body, cx, acc)
  end

  defp walk({:fixrec, lambdas, body}, cx, acc) do
    acc = Enum.reduce(lambdas, acc, fn {_names, fbody}, acc -> walk_all(fbody, cx, acc) end)
    walk_all(body, cx, acc)
  end

  defp walk({:known_call, _depth, _slot, _names, args, _name, _pos}, cx, acc),
    do: walk_all(args, cx, acc)

  defp walk({:quasi, template}, cx, acc), do: walk_template(template, cx, acc)

  defp walk({:guard, _names, clauses, body}, cx, acc) do
    acc = Enum.reduce(clauses, acc, &walk_clause(&1, cx, &2))
    walk_all(body, cx, acc)
  end

  defp walk_template({:qc, _}, _cx, acc), do: acc
  defp walk_template({:qu, expr}, cx, acc), do: walk(expr, cx, acc)
  defp walk_template({:qcons, h, t}, cx, acc), do: walk_template(t, cx, walk_template(h, cx, acc))
  defp walk_template({:qsplice, expr, t}, cx, acc), do: walk_template(t, cx, walk(expr, cx, acc))
  defp walk_template({:qvec, t}, cx, acc), do: walk_template(t, cx, acc)

  defp walk_clause({:else, body}, cx, acc), do: walk_all(body, cx, acc)
  defp walk_clause({:test, test}, cx, acc), do: walk(test, cx, acc)
  # An arrow clause calls its procedure with the test's value.
  defp walk_clause({:arrow, test, proc, pos}, cx, acc) do
    acc = walk_all([test, proc], cx, acc)
    check_arity({:app, proc, [test], pos}, cx, acc)
  end

  defp walk_clause({:test_body, test, body}, cx, acc), do: walk_all([test | body], cx, acc)
  defp walk_clause({:bad, e}, cx, acc), do: [diagnostic(:syntax_error, e, cx.file) | acc]

  # A global is bound when the name is known. A marked name the script
  # never defines falls back to its base name at run time (see
  # `Schooner.Eval.Analyze`), which is lexical or another global.
  defp bound?({:gref, name, marked, _pos}, cx) do
    Map.has_key?(cx.known, name) or
      case marked do
        nil -> false
        {:gref, _, _, _} -> bound?(marked, cx)
        _lexical -> true
      end
  end

  defp check_arity({:app, {:gref, name, _, _} = head, args, pos}, cx, acc) do
    with arity when arity != :unknown <- callee_arity(head, cx),
         false <- improper?(args),
         got = length(args),
         false <- arity_ok?(arity, got) do
      reason = {:arity_mismatch, display_name(name), expected(arity), got}
      [diagnostic(:arity, EvalError.exception(reason: reason), cx.file, pos) | acc]
    else
      _ -> acc
    end
  end

  defp check_arity(_app, _cx, acc), do: acc

  # A marked name whose fallback is lexical can reach that local
  # procedure until a definition of the marked name runs.
  defp callee_arity({:gref, name, marked, _pos}, cx) do
    case {cx.known, marked} do
      {_, {:rref, _, _, _, _, _}} -> :unknown
      {_, {:lref, _, _}} -> :unknown
      {%{^name => arity}, _} -> arity
      {_, {:gref, _, _, _}} -> callee_arity(marked, cx)
      _ -> :unknown
    end
  end

  # Analysis puts the error for an improper argument list in the last
  # argument's place.
  defp improper?([]), do: false
  defp improper?(args), do: match?({:raise, %EvalError{}}, List.last(args))

  defp arity_ok?(n, got) when is_integer(n), do: got == n
  defp arity_ok?({:at_least, n}, got), do: got >= n
  defp arity_ok?({:between, lo, hi}, got), do: got >= lo and got <= hi

  defp expected(n) when is_integer(n), do: {:exact, n}
  defp expected(spec), do: spec

  defp display_name(name) do
    case SyntaxRules.strip_mark(name) do
      {:ok, base} -> base
      :error -> name
    end
  end

  # ---------------------------------------------------------------------------
  # Diagnostics
  # ---------------------------------------------------------------------------

  defp syntax_diagnostic(reason, pos, file),
    do: diagnostic(:syntax_error, EvalError.exception(reason: reason), file, pos)

  defp diagnostic(code, e, file, pos),
    do: diagnostic(code, Location.attach(e, Location.new(nil, pos)), file)

  defp diagnostic(code, e, file) do
    %Diagnostic{
      severity: :error,
      code: code,
      message: message(e),
      location: e.location && %{e.location | file: file}
    }
  end

  # The exception's message without a location prefix. Lexer and
  # reader errors describe their position in the message unless the
  # location names a file, so name a placeholder file and strip the
  # prefix that adds.
  defp message(%{location: %Location{file: nil} = loc} = e) do
    e
    |> Location.put_file("-")
    |> Exception.message()
    |> String.replace_prefix(Location.prefix(%{loc | file: "-"}), "")
  end

  defp message(e), do: Exception.message(e)
end
