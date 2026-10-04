defmodule Schooner.Expander.SyntaxRules do
  @moduledoc """
  Compiles `syntax-rules` forms into transformer closures and
  instantiates the chosen rule's template with hygienic alpha-renaming.

  ## Compiled shapes

  Patterns and templates are compiled once, when the `syntax-rules`
  form is compiled, so each macro use only matches the input against
  the compiled patterns and walks the chosen compiled template.

  Pattern AST nodes:

    * `:wild`
    * `{:literal, name}` — matches an identifier whose name equals
      `name` (modulo mark-stripping)
    * `{:pvar, name, depth}` — pattern variable; `depth` is the number
      of enclosing ellipses (used to validate template uses)
    * `{:const, value}` — matches `value` by `equal?` (r7rs §4.3.2:
      "P is a datum and F is equal to P in the sense of the equal?
      procedure")
    * `{:list, head_pats, tail_pat}` — proper or improper list;
      `tail_pat` is `[]` for a proper list
    * `{:list_ell, pre_pats, ell_pat, post_pats, tail_pat}` — list with
      one ellipsis
    * `{:vector, pats}` / `{:vector_ell, pre_pats, ell_pat, post_pats}` —
      the vector counterparts

  Template AST nodes:

    * `{:t_sym, name}` — literal identifier from the template
    * `{:t_pvar, name, depth}` — reference to a pattern variable
    * `{:t_const, value}` — non-symbol leaf
    * `{:t_quote, datum}` — `(quote datum)`; identifiers in `datum`
      other than pattern variables are emitted without hygiene marks
    * `{:t_list, items, tail}` — list (`items` is a list of
      `{element_template, ellipsis_count}` tuples; `ellipsis_count` is
      0 for plain elements and ≥ 1 for ellipsis-driven elements)
    * `{:t_vector, items}`

  ## Hygiene

  At instantiation time each template-introduced identifier is
  rewritten to `name <> @mark_separator <> Integer.to_string(mark)`
  where `mark` is a fresh integer per expansion and the separator
  is a NUL byte (invalid in r7rs identifiers, so the marked name
  cannot collide with anything a user can write). Identifiers in
  `@core_keywords` are left unmarked. Pattern variables are
  substituted verbatim, preserving any marks on user-supplied
  identifiers.

  At lookup time (in the expander's syntax env and in the evaluator's
  runtime env), an unmarked-base fallback handles free template
  references — a marked `+` is bound nowhere lexically, so the
  lookup strips the mark and finds the global `+`. Template-
  introduced binders such as the `t` in `(let ((t e1)) ...)` keep
  the mark through both the binding and reference sites, which is
  what makes the macro hygienic.

  ## Positions

  A transformer takes the macro use and its `Schooner.Reader` position
  tree (or `nil`) and returns the expansion with a tree for it. Pattern
  variables are bound to `{form, tree}`, so each substituted sub-form
  keeps its own tree, and every node the template introduces is placed
  at the macro use.
  """

  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Expander.Error
  alias Schooner.Expander.Positions, as: Pos
  alias Schooner.Value

  @ellipsis "..."
  @mark_separator <<0>>

  @core_keywords MapSet.new(~w(
    quote if lambda define define-values begin set!
    define-syntax let-syntax letrec-syntax syntax-rules
    quasiquote unquote unquote-splicing
    ...
  ))

  @doc """
  Compile a `syntax-rules` form into a transformer of arity 2: the form
  being expanded and its position tree (or `nil`) → the expanded form
  and its position tree.

  The transformer raises `Schooner.Eval.Error` with reason
  `{:bad_special_form, name}` if no rule matches the supplied form:
  the same error a malformed core special form produces.
  """
  @spec compile(Value.t()) :: (Value.t(), Pos.t() -> {Value.t(), Pos.t()})
  def compile([{:sym, "syntax-rules"} | tail]) do
    {literals, rules_form} = parse_spec_head(tail)
    rules = parse_rules(rules_form, literals)

    fn form, tree ->
      mark = :erlang.unique_integer([:positive])
      dispatch(rules, form, tree, mark)
    end
  end

  def compile(_), do: raise(Error, reason: {:bad_syntax, "syntax-rules"})

  # Local, inlined copies of `Positions.car/1` and `Positions.cdr/1`:
  # these run for every element of every form expanded.
  @compile {:inline, car: 1, cdr: 1}
  defp car({:pair, _, car, _}), do: car
  defp car(_), do: nil
  defp cdr({:pair, _, _, cdr}), do: cdr
  defp cdr(_), do: nil

  @doc """
  If `name` carries a hygiene mark, return `{:ok, base_name}` with the
  mark removed. Returns `:error` otherwise. Useful for the evaluator's
  fallback lookup and for the expander when an introduced keyword
  needs to be recognised as its base form.

  Checks with a non-allocating `:binary.match/2` before calling
  `:binary.split/2`, because most names are unmarked and every
  user-written variable reference goes through this on a lookup miss.
  """
  @spec strip_mark(binary()) :: {:ok, binary()} | :error
  def strip_mark(name) when is_binary(name) do
    case :binary.match(name, @mark_separator) do
      :nomatch ->
        :error

      _ ->
        [base, _mark] = :binary.split(name, @mark_separator)
        {:ok, base}
    end
  end

  @doc false
  # Split a name into its base name and its marks, oldest first: `[]`
  # for an unmarked name, and more than one for an identifier a macro
  # introduced into the output of another macro's template. A mark is
  # a separator followed by digits at the end of the name, so a NUL
  # the script wrote itself (`|a\x0;b|`) is left in the base name.
  @spec split_marks(binary()) :: {binary(), [binary()]}
  def split_marks(name) when is_binary(name) do
    [first | segments] = :binary.split(name, @mark_separator, [:global])
    {marks, rest} = segments |> Enum.reverse() |> Enum.split_while(&mark?/1)
    {Enum.join([first | Enum.reverse(rest)], @mark_separator), Enum.reverse(marks)}
  end

  defp mark?(<<_, _::binary>> = segment),
    do: for(<<c <- segment>>, do: c in ?0..?9) |> Enum.all?()

  defp mark?(_segment), do: false

  @doc false
  # Renumber the hygiene marks in `values` 1, 2, 3, ... in the order
  # they first appear, walking each value depth first, so expansions
  # print the same on every run. A mark keeps its number across all of
  # `values`, so identifiers that were the same stay the same, and
  # different ones stay different.
  @spec renumber_marks([Value.t()]) :: [Value.t()]
  def renumber_marks(values) when is_list(values) do
    {values, _numbers} = Enum.map_reduce(values, %{}, &renumber/2)
    values
  end

  defp renumber({:sym, name} = sym, numbers) do
    case split_marks(name) do
      {_base, []} ->
        {sym, numbers}

      {base, marks} ->
        {marks, numbers} = Enum.map_reduce(marks, numbers, &renumber_mark/2)
        {{:sym, Enum.reduce(marks, base, &mark_name(&2, &1))}, numbers}
    end
  end

  defp renumber([h | t], numbers) do
    {h, numbers} = renumber(h, numbers)
    {t, numbers} = renumber(t, numbers)
    {[h | t], numbers}
  end

  defp renumber({:vector, items}, numbers) do
    {items, numbers} = items |> Tuple.to_list() |> Enum.map_reduce(numbers, &renumber/2)
    {{:vector, List.to_tuple(items)}, numbers}
  end

  # An expanded `define-record-type` embeds its type's name, renamed
  # like the definitions when a macro introduced it.
  defp renumber({:record_type, name, id}, numbers) do
    {{:sym, name}, numbers} = renumber({:sym, name}, numbers)
    {{:record_type, name, id}, numbers}
  end

  defp renumber(other, numbers), do: {other, numbers}

  defp renumber_mark(mark, numbers) do
    case numbers do
      %{^mark => n} ->
        {n, numbers}

      _ ->
        n = map_size(numbers) + 1
        {n, Map.put(numbers, mark, n)}
    end
  end

  # ---------------------------------------------------------------------------
  # syntax-rules parsing
  # ---------------------------------------------------------------------------

  defp parse_spec_head([literals_form | rules_form]) do
    {parse_literals(literals_form, MapSet.new()), rules_form}
  end

  defp parse_spec_head(_), do: raise(Error, reason: {:bad_syntax, "syntax-rules"})

  defp parse_literals([], acc), do: acc

  defp parse_literals([{:sym, name} | rest], acc) do
    parse_literals(rest, MapSet.put(acc, name))
  end

  defp parse_literals(_, _), do: raise(Error, reason: {:bad_syntax, "syntax-rules"})

  defp parse_rules([], _literals), do: []

  defp parse_rules([[pat | [tmpl | []]] | rest], literals) do
    # The macro keyword's position in the pattern is matched against the
    # macro name regardless of what the rule writes (r7rs §4.3.2). Force
    # it to `:wild` so a `_` literal in the literals list does not turn
    # the conventional `_` placeholder into "match only the literal `_`".
    cpat = pat |> compile_pattern(literals, 0) |> ignore_keyword_position()
    pvars = collect_pvars(cpat, %{})
    ctmpl = compile_template(tmpl, pvars, false)
    [{cpat, ctmpl} | parse_rules(rest, literals)]
  end

  defp parse_rules(_, _), do: raise(Error, reason: {:bad_syntax, "syntax-rules"})

  defp ignore_keyword_position({:list, [_kw | rest], tail}),
    do: {:list, [:wild | rest], tail}

  defp ignore_keyword_position({:list_ell, [_kw | pre], ell, post, tail}),
    do: {:list_ell, [:wild | pre], ell, post, tail}

  defp ignore_keyword_position(other), do: other

  # ---------------------------------------------------------------------------
  # Pattern compilation
  # ---------------------------------------------------------------------------

  # `_` is the wildcard *unless* the user puts `_` in the literals list,
  # in which case it matches only the literal `_` symbol (r7rs §4.3.2).
  defp compile_pattern({:sym, "_"}, literals, _depth) do
    if MapSet.member?(literals, "_"), do: {:literal, "_"}, else: :wild
  end

  defp compile_pattern({:sym, @ellipsis}, _literals, _depth) do
    raise Error, reason: {:bad_pattern, "stray ellipsis"}
  end

  defp compile_pattern({:sym, name}, literals, depth) do
    if MapSet.member?(literals, name) do
      {:literal, name}
    else
      {:pvar, name, depth}
    end
  end

  defp compile_pattern([], _literals, _depth), do: {:list, [], []}

  defp compile_pattern([_ | _] = list, literals, depth) do
    compile_list_pattern(list, literals, depth, [])
  end

  defp compile_pattern({:vector, t}, literals, depth) do
    items = t |> Tuple.to_list() |> Value.list()

    case compile_list_pattern(items, literals, depth, []) do
      {:list, head, []} -> {:vector, head}
      {:list_ell, pre, ell, post, []} -> {:vector_ell, pre, ell, post}
      _ -> raise Error, reason: {:bad_pattern, "vector pattern with dotted tail"}
    end
  end

  defp compile_pattern(other, _literals, _depth), do: {:const, other}

  defp compile_list_pattern(
         [head | [{:sym, @ellipsis} | rest]],
         literals,
         depth,
         acc
       ) do
    ell_pat = compile_pattern(head, literals, depth + 1)
    {post, tail} = compile_post_ellipsis(rest, literals, depth, [])
    {:list_ell, Enum.reverse(acc), ell_pat, post, tail}
  end

  defp compile_list_pattern([head | rest], literals, depth, acc) do
    compile_list_pattern(rest, literals, depth, [compile_pattern(head, literals, depth) | acc])
  end

  defp compile_list_pattern([], _literals, _depth, acc) do
    {:list, Enum.reverse(acc), []}
  end

  defp compile_list_pattern(other, literals, depth, acc) do
    {:list, Enum.reverse(acc), compile_pattern(other, literals, depth)}
  end

  defp compile_post_ellipsis([], _literals, _depth, acc), do: {Enum.reverse(acc), []}

  defp compile_post_ellipsis([{:sym, @ellipsis} | _], _literals, _depth, _acc) do
    raise Error, reason: {:bad_pattern, "two ellipses in one list"}
  end

  defp compile_post_ellipsis([head | rest], literals, depth, acc) do
    compile_post_ellipsis(rest, literals, depth, [compile_pattern(head, literals, depth) | acc])
  end

  defp compile_post_ellipsis(other, literals, depth, acc) do
    {Enum.reverse(acc), compile_pattern(other, literals, depth)}
  end

  # ---------------------------------------------------------------------------
  # Pattern variable collection
  # ---------------------------------------------------------------------------

  defp collect_pvars(:wild, acc), do: acc
  defp collect_pvars([], acc), do: acc
  defp collect_pvars({:literal, _}, acc), do: acc
  defp collect_pvars({:const, _}, acc), do: acc

  defp collect_pvars({:pvar, name, depth}, acc) do
    if Map.has_key?(acc, name) do
      raise Error, reason: :duplicate_pattern_var
    else
      Map.put(acc, name, depth)
    end
  end

  defp collect_pvars({:list, head, tail}, acc) do
    acc = Enum.reduce(head, acc, &collect_pvars/2)
    collect_pvars(tail, acc)
  end

  defp collect_pvars({:list_ell, pre, ell, post, tail}, acc) do
    acc = Enum.reduce(pre, acc, &collect_pvars/2)
    acc = collect_pvars(ell, acc)
    acc = Enum.reduce(post, acc, &collect_pvars/2)
    collect_pvars(tail, acc)
  end

  defp collect_pvars({:vector, items}, acc) do
    Enum.reduce(items, acc, &collect_pvars/2)
  end

  defp collect_pvars({:vector_ell, pre, ell, post}, acc) do
    acc = Enum.reduce(pre, acc, &collect_pvars/2)
    acc = collect_pvars(ell, acc)
    Enum.reduce(post, acc, &collect_pvars/2)
  end

  # ---------------------------------------------------------------------------
  # Template compilation
  # ---------------------------------------------------------------------------

  # When `escape?` is true, every `...` inside the template is treated as
  # an ordinary identifier. r7rs §4.3.2 ellipsis-escape: `(... template)`
  # is identical to `template` except that ellipses inside have no
  # special meaning.
  defp compile_template({:sym, @ellipsis}, _pvars, false) do
    raise Error, reason: {:bad_template, "stray ellipsis"}
  end

  defp compile_template({:sym, @ellipsis}, _pvars, true), do: {:t_sym, @ellipsis}

  defp compile_template({:sym, name}, pvars, _escape?) do
    case Map.fetch(pvars, name) do
      {:ok, depth} -> {:t_pvar, name, depth}
      :error -> {:t_sym, name}
    end
  end

  defp compile_template([], _pvars, _escape?), do: {:t_list, [], []}

  # Ellipsis-escape `(... template)`. Only valid outside an existing
  # escape — once `escape?` is set, `...` is an ordinary identifier.
  defp compile_template([{:sym, @ellipsis} | [tmpl | []]], pvars, false) do
    compile_template(tmpl, pvars, true)
  end

  # `(quote datum)` in a template emits `(quote datum)` verbatim. The
  # datum is data — its non-pattern-variable identifiers must NOT
  # pick up hygiene marks so a quoted symbol comes out the way the
  # author wrote it. Pattern variables inside the datum do still
  # substitute (the standard `case` macro relies on `'(d ...)` to
  # produce a list of the literal datums for `memv`).
  defp compile_template([{:sym, "quote"} | [datum | []]], pvars, _escape?) do
    {:t_quote, compile_quoted_datum(datum, pvars)}
  end

  defp compile_template([_ | _] = list, pvars, escape?) do
    compile_template_list(list, pvars, [], escape?)
  end

  defp compile_template({:vector, t}, pvars, escape?) do
    items = t |> Tuple.to_list() |> Value.list()
    {:t_list, list_items, _tail} = compile_template_list(items, pvars, [], escape?)
    {:t_vector, list_items}
  end

  defp compile_template(other, _pvars, _escape?), do: {:t_const, other}

  defp compile_template_list([head | rest], pvars, acc, escape?) do
    item_tmpl = compile_template(head, pvars, escape?)
    {n, after_dots} = count_template_ellipses(rest, 0, escape?)
    compile_template_list(after_dots, pvars, [{item_tmpl, n} | acc], escape?)
  end

  defp compile_template_list([], _pvars, acc, _escape?),
    do: {:t_list, Enum.reverse(acc), []}

  defp compile_template_list(other, pvars, acc, escape?) do
    {:t_list, Enum.reverse(acc), compile_template(other, pvars, escape?)}
  end

  defp count_template_ellipses([{:sym, @ellipsis} | rest], n, false) do
    count_template_ellipses(rest, n + 1, false)
  end

  defp count_template_ellipses(rest, n, _escape?), do: {n, rest}

  # Walk a quoted datum into a parallel AST. Pattern variables within
  # the datum are tagged for substitution (with their pattern depth
  # preserved); every other identifier becomes a literal `:q_sym`
  # whose name will be emitted verbatim, never with a hygiene mark.
  # Ellipsis sequences (`(d ...)`) are recognised so a quoted spread
  # behaves the same way a non-quoted spread does.
  defp compile_quoted_datum({:sym, @ellipsis}, _pvars) do
    raise Error, reason: {:bad_template, "stray ellipsis in quoted datum"}
  end

  defp compile_quoted_datum({:sym, name}, pvars) do
    case Map.fetch(pvars, name) do
      {:ok, depth} -> {:q_pvar, name, depth}
      :error -> {:q_sym, name}
    end
  end

  defp compile_quoted_datum([], _pvars), do: {:q_list, [], :q_null}

  defp compile_quoted_datum([_ | _] = list, pvars) do
    compile_quoted_list(list, pvars, [])
  end

  defp compile_quoted_datum({:vector, t}, pvars) do
    items =
      t
      |> Tuple.to_list()
      |> Value.list()
      |> compile_quoted_list(pvars, [])

    case items do
      {:q_list, list_items, :q_null} -> {:q_vector, list_items}
      _ -> raise Error, reason: {:bad_template, "vector quoted datum has dotted tail"}
    end
  end

  defp compile_quoted_datum(other, _pvars), do: {:q_const, other}

  defp compile_quoted_list([head | rest], pvars, acc) do
    item = compile_quoted_datum(head, pvars)
    {n, after_dots} = count_template_ellipses(rest, 0, false)
    compile_quoted_list(after_dots, pvars, [{item, n} | acc])
  end

  defp compile_quoted_list([], _pvars, acc), do: {:q_list, Enum.reverse(acc), :q_null}

  defp compile_quoted_list(other, pvars, acc) do
    {:q_list, Enum.reverse(acc), compile_quoted_datum(other, pvars)}
  end

  # ---------------------------------------------------------------------------
  # Dispatch — try each rule in order
  # ---------------------------------------------------------------------------

  defp dispatch([], form, _tree, _mark) do
    # A use that matches no rule raises the same `Schooner.Eval.Error`
    # `{:bad_special_form, name}` as a malformed core special form, so
    # a malformed `let` and a malformed `if` fail the same way even
    # though one is a macro.
    raise EvalError, reason: {:bad_special_form, form_keyword(form)}
  end

  defp dispatch([{cpat, ctmpl} | rest], form, tree, mark) do
    case match(cpat, form, tree, %{}) do
      {:ok, env} -> instantiate(ctmpl, env, mark, leaf(tree))
      :no_match -> dispatch(rest, form, tree, mark)
    end
  end

  # The tree of every leaf the template introduces: one shared term at
  # the macro use's position, or `nil` when the use has no tree, in
  # which case no trees are built at all.
  defp leaf(nil), do: nil
  defp leaf(tree), do: {:atom, Pos.at(tree)}

  defp form_keyword([{:sym, name} | _]), do: name
  defp form_keyword(_), do: "<form>"

  # ---------------------------------------------------------------------------
  # Pattern matching
  # ---------------------------------------------------------------------------

  # `tree` is the input's position tree, walked alongside it so that
  # each pattern variable is bound to `{form, tree}`.
  defp match(:wild, _input, _tree, env), do: {:ok, env}

  # `[]` shows up both as a compiled pattern (from a `()` literal)
  # and as the "no dotted tail" sentinel inside a `{:list, _, []}`
  # term. In either reading the matching rule is the same: only
  # the empty list satisfies it.
  defp match([], [], _tree, env), do: {:ok, env}
  defp match([], _, _tree, _), do: :no_match

  defp match({:literal, name}, {:sym, sym}, _tree, env) do
    if same_identifier?(sym, name), do: {:ok, env}, else: :no_match
  end

  defp match({:literal, _}, _, _tree, _), do: :no_match

  defp match({:pvar, name, _depth}, input, tree, env) do
    {:ok, Map.put(env, name, {input, tree})}
  end

  defp match({:const, v}, input, _tree, env) do
    if Value.equal?(v, input), do: {:ok, env}, else: :no_match
  end

  defp match({:list, head_pats, tail_pat}, input, tree, env) do
    case match_each(head_pats, input, tree, env) do
      {:ok, env2, rest, rest_tree} -> match(tail_pat, rest, rest_tree, env2)
      :no_match -> :no_match
    end
  end

  defp match({:list_ell, pre, ell, post, tail}, input, tree, env) do
    match_list_ell(pre, ell, post, tail, input, tree, env)
  end

  defp match({:vector, items}, {:vector, t}, tree, env) do
    list = Value.list(Tuple.to_list(t))

    case match_each(items, list, vector_tree(tree), env) do
      {:ok, env2, [], _} -> {:ok, env2}
      _ -> :no_match
    end
  end

  defp match({:vector_ell, pre, ell, post}, {:vector, t}, tree, env) do
    list = Value.list(Tuple.to_list(t))
    match_list_ell(pre, ell, post, [], list, vector_tree(tree), env)
  end

  defp match(_, _, _, _), do: :no_match

  # A vector's items are matched as a list, so walk them as one.
  defp vector_tree({:vector, pos, trees}), do: Pos.list(trees, nil, {:atom, pos})
  defp vector_tree(_), do: nil

  defp match_each([], rest, tree, env), do: {:ok, env, rest, tree}

  defp match_each([p | rest_pats], [h | t], tree, env) do
    case match(p, h, car(tree), env) do
      {:ok, env2} -> match_each(rest_pats, t, cdr(tree), env2)
      :no_match -> :no_match
    end
  end

  defp match_each(_, _, _, _), do: :no_match

  defp match_list_ell(pre_pats, ell_pat, post_pats, tail_pat, input, tree, env) do
    case match_each(pre_pats, input, tree, env) do
      {:ok, env2, rest_after_pre, rest_tree} ->
        match_after_pre(ell_pat, post_pats, tail_pat, rest_after_pre, rest_tree, env2)

      :no_match ->
        :no_match
    end
  end

  defp match_after_pre(ell_pat, post_pats, tail_pat, input, tree, env) do
    {items, tail_input, tail_tree} = collect_proper(input, tree)
    num_post = length(post_pats)
    num_items = length(items)

    if num_items < num_post do
      :no_match
    else
      {ell_items, post_items} = Enum.split(items, num_items - num_post)

      with {:ok, ell_bindings} <- match_ellipsis(ell_pat, ell_items),
           env2 <- merge_bindings(env, ell_bindings),
           {rest_form, rest_tree} <- items_with_tail(post_items, tail_input, tail_tree, tree),
           {:ok, env3, leftover, leftover_tree} <-
             match_each(post_pats, rest_form, rest_tree, env2),
           {:ok, env4} <- match(tail_pat, leftover, leftover_tree, env3) do
        {:ok, env4}
      else
        _ -> :no_match
      end
    end
  end

  # The proper elements of `input`, each as `{form, tree}`, and its
  # tail with the tail's tree.
  defp collect_proper([], tree), do: {[], [], tree}

  defp collect_proper([h | t], tree) do
    {rest, tail, tail_tree} = collect_proper(t, cdr(tree))
    {[{h, car(tree)} | rest], tail, tail_tree}
  end

  defp collect_proper(other, tree), do: {[], other, tree}

  defp items_with_tail(items, tail, tail_tree, tree) do
    {forms, trees} = Enum.unzip(items)
    {list_with_tail(forms, tail), tree && Pos.list(trees, tail_tree, tree)}
  end

  # `items_with_tail/4` in one pass, for template instantiation. With
  # no `leaf`, only the form is built.
  defp build_list([], tail, tail_tree, _leaf), do: {tail, tail_tree}

  defp build_list([{form, _tree} | rest], tail, tail_tree, nil) do
    {rest, nil} = build_list(rest, tail, tail_tree, nil)
    {[form | rest], nil}
  end

  defp build_list([{form, tree} | rest], tail, tail_tree, {:atom, pos} = leaf) do
    {rest, rest_tree} = build_list(rest, tail, tail_tree, leaf)
    {[form | rest], {:pair, pos, tree, rest_tree}}
  end

  defp list_with_tail([], tail), do: tail
  defp list_with_tail([h | t], tail), do: [h | list_with_tail(t, tail)]

  defp match_ellipsis(ell_pat, items) do
    pvars = collect_pvars(ell_pat, %{}) |> Map.keys()
    initial = Map.new(pvars, &{&1, []})

    items
    |> Enum.reduce_while({:ok, initial}, &accumulate_ellipsis_iter(&1, &2, ell_pat, pvars))
    |> finalise_ellipsis()
  end

  defp accumulate_ellipsis_iter({item, tree}, {:ok, acc}, ell_pat, pvars) do
    case match(ell_pat, item, tree, %{}) do
      {:ok, item_env} -> {:cont, {:ok, push_ellipsis_iter(acc, item_env, pvars)}}
      :no_match -> {:halt, :no_match}
    end
  end

  defp push_ellipsis_iter(acc, item_env, pvars) do
    Enum.reduce(pvars, acc, fn name, a ->
      Map.update!(a, name, fn list -> [Map.get(item_env, name) | list] end)
    end)
  end

  defp finalise_ellipsis({:ok, acc}) do
    {:ok, Map.new(acc, fn {k, list} -> {k, {:ellipsis_list, Enum.reverse(list)}} end)}
  end

  defp finalise_ellipsis(:no_match), do: :no_match

  defp merge_bindings(env, ell_bindings) do
    Enum.reduce(ell_bindings, env, fn {name, value}, acc -> Map.put(acc, name, value) end)
  end

  defp same_identifier?(name, name), do: true

  defp same_identifier?(name1, name2) do
    base1 = base_name(name1)
    base2 = base_name(name2)
    base1 == base2
  end

  defp base_name(name) do
    case strip_mark(name) do
      {:ok, base} -> base
      :error -> name
    end
  end

  # ---------------------------------------------------------------------------
  # Template instantiation
  # ---------------------------------------------------------------------------

  # Each clause returns the instantiated form with its position tree.
  # Pattern variables bring their own trees; everything the template
  # introduces is placed at the macro use, whose leaf tree is `leaf`.
  defp instantiate([], _env, _mark, leaf), do: {[], leaf}

  defp instantiate({:t_sym, name}, _env, mark, leaf) do
    if MapSet.member?(@core_keywords, name) do
      {{:sym, name}, leaf}
    else
      {{:sym, mark_name(name, mark)}, leaf}
    end
  end

  defp instantiate({:t_pvar, name, _depth}, env, _mark, _leaf) do
    case Map.fetch(env, name) do
      {:ok, {:ellipsis_list, _}} ->
        raise Error, reason: {:bad_template, "pattern variable `#{name}` used outside ellipsis"}

      {:ok, bound} ->
        bound

      :error ->
        raise Error, reason: {:bad_template, "unbound pattern variable `#{name}`"}
    end
  end

  defp instantiate({:t_const, value}, _env, _mark, leaf), do: {value, leaf}

  # Quoted data is never analysed, so its tree is a single leaf.
  defp instantiate({:t_quote, q_datum}, env, _mark, leaf) do
    form = [{:sym, "quote"} | [instantiate_quoted(q_datum, env) | []]]
    {form, leaf && {:pair, elem(leaf, 1), leaf, {:pair, elem(leaf, 1), leaf, leaf}}}
  end

  defp instantiate({:t_list, items, tail}, env, mark, leaf) do
    items = expand_template_items(items, env, mark, leaf)
    {tail_form, tail_tree} = instantiate(tail, env, mark, leaf)
    build_list(items, tail_form, tail_tree, leaf)
  end

  defp instantiate({:t_vector, items}, env, mark, leaf) do
    {forms, trees} = items |> expand_template_items(env, mark, leaf) |> Enum.unzip()
    {{:vector, List.to_tuple(forms)}, leaf && {:vector, elem(leaf, 1), trees}}
  end

  defp instantiate_quoted(:q_null, _env), do: []
  defp instantiate_quoted({:q_sym, name}, _env), do: {:sym, name}
  defp instantiate_quoted({:q_const, v}, _env), do: v

  defp instantiate_quoted({:q_pvar, name, _depth}, env) do
    case Map.fetch(env, name) do
      {:ok, {:ellipsis_list, _}} ->
        raise Error,
          reason: {:bad_template, "pattern variable `#{name}` used outside ellipsis (in quote)"}

      {:ok, {value, _tree}} ->
        value

      :error ->
        raise Error, reason: {:bad_template, "unbound pattern variable `#{name}`"}
    end
  end

  defp instantiate_quoted({:q_list, items, tail}, env) do
    head_data = expand_quoted_items(items, env)
    list_with_tail(head_data, instantiate_quoted(tail, env))
  end

  defp instantiate_quoted({:q_vector, items}, env) do
    {:vector, items |> expand_quoted_items(env) |> List.to_tuple()}
  end

  defp expand_quoted_items([], _env), do: []

  defp expand_quoted_items([{q, 0} | rest], env) do
    [instantiate_quoted(q, env) | expand_quoted_items(rest, env)]
  end

  defp expand_quoted_items([{q, n} | rest], env) when n >= 1 do
    expand_quoted_ellipsis(q, n, env) ++ expand_quoted_items(rest, env)
  end

  defp expand_quoted_ellipsis(q, 0, env), do: [instantiate_quoted(q, env)]

  defp expand_quoted_ellipsis(q, n, env) when n >= 1 do
    pvars_used = quoted_pvars_at_depth(q, n)

    if pvars_used == [] do
      raise Error, reason: {:ellipsis_no_pattern_var, "quoted template"}
    end

    pvars_used
    |> pvar_lists(env)
    |> validate_pvar_lengths(pvars_used)
    |> iterate_quoted_ellipsis(q, n, env, pvars_used)
  end

  defp iterate_quoted_ellipsis([[] | _], _q, _n, _env, _pvars), do: []
  defp iterate_quoted_ellipsis([], _q, _n, _env, _pvars), do: []

  defp iterate_quoted_ellipsis(lists, q, n, env, pvars_used) do
    {heads, tails} = peel_lists(lists, [], [])
    sub_env = put_pvars(env, pvars_used, heads)

    expand_quoted_ellipsis(q, n - 1, sub_env) ++
      iterate_quoted_ellipsis(tails, q, n, env, pvars_used)
  end

  defp expand_template_items([], _env, _mark, _leaf), do: []

  defp expand_template_items([{tmpl, 0} | rest], env, mark, leaf) do
    [instantiate(tmpl, env, mark, leaf) | expand_template_items(rest, env, mark, leaf)]
  end

  defp expand_template_items([{tmpl, n} | rest], env, mark, leaf) when n >= 1 do
    expand_ellipsis(tmpl, n, env, mark, leaf) ++ expand_template_items(rest, env, mark, leaf)
  end

  defp expand_ellipsis(tmpl, 0, env, mark, leaf), do: [instantiate(tmpl, env, mark, leaf)]

  defp expand_ellipsis(tmpl, n, env, mark, leaf) when n >= 1 do
    pvars_used = template_pvars_at_depth(tmpl, n)

    if pvars_used == [] do
      raise Error, reason: {:ellipsis_no_pattern_var, "template"}
    end

    pvars_used
    |> pvar_lists(env)
    |> validate_pvar_lengths(pvars_used)
    |> iterate_ellipsis(tmpl, n, env, mark, leaf, pvars_used)
  end

  # Walk the driving pvars' `:ellipsis_list`s in lockstep, peeling one
  # element off each per step and binding them in the sub-env; this
  # keeps the work O(N) rather than O(N²) from indexing each list.
  # `validate_pvar_lengths/2` has already checked that the lists have
  # equal length, so stopping when the first is empty is enough.
  defp iterate_ellipsis([[] | _], _tmpl, _n, _env, _mark, _leaf, _pvars), do: []
  defp iterate_ellipsis([], _tmpl, _n, _env, _mark, _leaf, _pvars), do: []

  defp iterate_ellipsis(lists, tmpl, n, env, mark, leaf, pvars_used) do
    {heads, tails} = peel_lists(lists, [], [])
    sub_env = put_pvars(env, pvars_used, heads)

    expand_ellipsis(tmpl, n - 1, sub_env, mark, leaf) ++
      iterate_ellipsis(tails, tmpl, n, env, mark, leaf, pvars_used)
  end

  defp peel_lists([], head_acc, tail_acc),
    do: {Enum.reverse(head_acc), Enum.reverse(tail_acc)}

  defp peel_lists([[h | t] | rest], head_acc, tail_acc),
    do: peel_lists(rest, [h | head_acc], [t | tail_acc])

  defp put_pvars(env, [], []), do: env

  defp put_pvars(env, [name | rest_names], [value | rest_values]),
    do: put_pvars(Map.put(env, name, value), rest_names, rest_values)

  defp pvar_lists(pvars_used, env) do
    Enum.map(pvars_used, fn name ->
      case Map.fetch(env, name) do
        {:ok, {:ellipsis_list, list}} ->
          list

        {:ok, _} ->
          raise Error,
            reason: {:bad_template, "pattern variable `#{name}` is not under an ellipsis"}

        :error ->
          raise Error, reason: {:bad_template, "unbound pattern variable `#{name}`"}
      end
    end)
  end

  defp validate_pvar_lengths(lists, pvars_used) do
    case lists |> Enum.map(&length/1) |> Enum.uniq() do
      [_] -> lists
      [] -> []
      _ -> raise Error, reason: {:ellipsis_count_mismatch, hd(pvars_used)}
    end
  end

  # All template-side pattern variables of depth ≥ `min`. Used to
  # decide which pvars drive an ellipsis: only those whose pattern depth
  # is at least the number of enclosing ellipses are eligible.
  defp template_pvars_at_depth([], _min), do: []
  defp template_pvars_at_depth({:t_pvar, name, depth}, min) when depth >= min, do: [name]
  defp template_pvars_at_depth({:t_pvar, _, _}, _min), do: []
  defp template_pvars_at_depth({:t_sym, _}, _min), do: []
  defp template_pvars_at_depth({:t_const, _}, _min), do: []

  defp template_pvars_at_depth({:t_quote, q}, min), do: quoted_pvars_at_depth(q, min)

  defp template_pvars_at_depth({:t_list, items, tail}, min) do
    items_pvars =
      Enum.flat_map(items, fn {tmpl, n} ->
        template_pvars_at_depth(tmpl, min + n)
      end)

    items_pvars ++ template_pvars_at_depth(tail, min)
  end

  defp template_pvars_at_depth({:t_vector, items}, min) do
    Enum.flat_map(items, fn {tmpl, n} ->
      template_pvars_at_depth(tmpl, min + n)
    end)
  end

  defp quoted_pvars_at_depth(:q_null, _min), do: []
  defp quoted_pvars_at_depth({:q_sym, _}, _min), do: []
  defp quoted_pvars_at_depth({:q_const, _}, _min), do: []
  defp quoted_pvars_at_depth({:q_pvar, name, depth}, min) when depth >= min, do: [name]
  defp quoted_pvars_at_depth({:q_pvar, _, _}, _min), do: []

  defp quoted_pvars_at_depth({:q_list, items, tail}, min) do
    items_pvars =
      Enum.flat_map(items, fn {q, n} ->
        quoted_pvars_at_depth(q, min + n)
      end)

    items_pvars ++ quoted_pvars_at_depth(tail, min)
  end

  defp quoted_pvars_at_depth({:q_vector, items}, min) do
    Enum.flat_map(items, fn {q, n} -> quoted_pvars_at_depth(q, min + n) end)
  end

  defp mark_name(name, mark) do
    name <> @mark_separator <> Integer.to_string(mark)
  end
end
