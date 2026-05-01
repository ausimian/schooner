defmodule Schooner.Expander.SyntaxRules do
  @moduledoc """
  Compiles `syntax-rules` forms into transformer closures and
  instantiates the chosen rule's template with hygienic alpha-renaming.

  ## Compiled shapes

  Patterns and templates are pre-compiled at `define-syntax` time so
  that each macro use only does the work specific to that input —
  pattern matching against a small AST and walking a small AST to
  emit code.

  Pattern AST nodes:

    * `:wild`
    * `{:literal, name}` — matches an identifier whose name equals
      `name` (modulo mark-stripping)
    * `{:pvar, name, depth}` — pattern variable; `depth` is the number
      of enclosing ellipses (used to validate template uses)
    * `{:const, value}` — matches `value` by `equal?` (r7rs §4.3.2:
      "P is a datum and F is equal to P in the sense of the equal?
      procedure")
    * `{:list, head_pats, tail_pat}` — proper-or-improper list
    * `{:list_ell, pre_pats, ell_pat, post_pats, tail_pat}` — list with
      one ellipsis

  Template AST nodes:

    * `{:t_sym, name}` — literal identifier from the template
    * `{:t_pvar, name, depth}` — reference to a pattern variable
    * `{:t_const, value}` — non-symbol leaf
    * `{:t_list, items, tail}` — list (`items` is a list of
      `{element_template, ellipsis_count}` tuples; `ellipsis_count` is
      0 for plain elements and ≥ 1 for ellipsis-driven elements)
    * `{:t_vector, items}`

  ## Hygiene

  At instantiation time each template-introduced identifier is
  rewritten to `name <> @mark_separator <> Integer.to_string(mark)`
  where `mark` is a fresh integer per expansion and the separator
  is a NUL byte (invalid in r7rs identifiers, so the marked name
  cannot collide with anything a user can write). Pattern variables
  are substituted verbatim, preserving any marks on user-supplied
  identifiers.

  At lookup time (in the expander's syntax env and in the evaluator's
  runtime env), an unmarked-base fallback handles free template
  references — a marked `+` is bound nowhere lexically, so the
  lookup strips the mark and finds the global `+`. Template-
  introduced binders such as the `t` in `(let ((t e1)) ...)` keep
  the mark through both the binding and reference sites, which is
  what makes the macro hygienic.
  """

  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Expander.Error
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
  Compile a `syntax-rules` form into a transformer of arity 1 (the
  form being expanded) → expanded form.

  The transformer raises `Schooner.Eval.Error` with reason
  `{:bad_special_form, name}` if no rule matches the supplied form,
  mirroring what the throwaway phase-7 evaluator branches did so
  that the regression tests preserved from that phase need no
  special-casing for the expansion-time exception class.
  """
  @spec compile(Value.t()) :: (Value.t() -> Value.t())
  def compile([{:sym, "syntax-rules"} | tail]) do
    {literals, rules_form} = parse_spec_head(tail)
    rules = parse_rules(rules_form, literals)

    fn form ->
      mark = :erlang.unique_integer([:positive])
      dispatch(rules, form, mark)
    end
  end

  def compile(_), do: raise(Error, reason: {:bad_syntax, "syntax-rules"})

  @doc """
  If `name` carries a hygiene mark, return `{:ok, base_name}` with the
  mark removed. Returns `:error` otherwise. Useful for the evaluator's
  fallback lookup and for the expander when an introduced keyword
  needs to be recognised as its base form.

  Short-circuits with a no-allocation `:binary.match/2` before
  falling into `:binary.split/2`, because the overwhelming common
  case is unmarked names — every plain user-written variable
  reference goes through this on a lookup miss.
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

  defp dispatch([], form, _mark) do
    # Phase 7 raised `Schooner.Eval.Error` with `{:bad_special_form,
    # name}` for malformed uses of derived forms. The macro layer
    # mirrors that contract: a use that matches no `syntax-rules`
    # clause is, from the caller's point of view, the same kind of
    # failure as a malformed special-form invocation, so the regression
    # tests carried over from phase 7 do not need to special-case the
    # macro expander's exception class.
    raise EvalError, reason: {:bad_special_form, form_keyword(form)}
  end

  defp dispatch([{cpat, ctmpl} | rest], form, mark) do
    case match(cpat, form, %{}) do
      {:ok, env} -> instantiate(ctmpl, env, mark)
      :no_match -> dispatch(rest, form, mark)
    end
  end

  defp form_keyword([{:sym, name} | _]), do: name
  defp form_keyword(_), do: "<form>"

  # ---------------------------------------------------------------------------
  # Pattern matching
  # ---------------------------------------------------------------------------

  defp match(:wild, _input, env), do: {:ok, env}

  # `[]` shows up both as a compiled pattern (from a `()` literal)
  # and as the "no dotted tail" sentinel inside a `{:list, _, []}`
  # term. In either reading the matching rule is the same: only
  # the empty list satisfies it.
  defp match([], [], env), do: {:ok, env}
  defp match([], _, _), do: :no_match

  defp match({:literal, name}, {:sym, sym}, env) do
    if same_identifier?(sym, name), do: {:ok, env}, else: :no_match
  end

  defp match({:literal, _}, _, _), do: :no_match

  defp match({:pvar, name, _depth}, input, env) do
    {:ok, Map.put(env, name, input)}
  end

  defp match({:const, v}, input, env) do
    if Value.equal?(v, input), do: {:ok, env}, else: :no_match
  end

  defp match({:list, head_pats, tail_pat}, input, env) do
    case match_each(head_pats, input, env) do
      {:ok, env2, rest} -> match(tail_pat, rest, env2)
      :no_match -> :no_match
    end
  end

  defp match({:list_ell, pre, ell, post, tail}, input, env) do
    match_list_ell(pre, ell, post, tail, input, env)
  end

  defp match({:vector, items}, {:vector, t}, env) do
    list = Value.list(Tuple.to_list(t))

    case match_each(items, list, env) do
      {:ok, env2, []} -> {:ok, env2}
      _ -> :no_match
    end
  end

  defp match({:vector_ell, pre, ell, post}, {:vector, t}, env) do
    list = Value.list(Tuple.to_list(t))
    match_list_ell(pre, ell, post, [], list, env)
  end

  defp match(_, _, _), do: :no_match

  defp match_each([], rest, env), do: {:ok, env, rest}

  defp match_each([p | rest_pats], [h | t], env) do
    case match(p, h, env) do
      {:ok, env2} -> match_each(rest_pats, t, env2)
      :no_match -> :no_match
    end
  end

  defp match_each(_, _, _), do: :no_match

  defp match_list_ell(pre_pats, ell_pat, post_pats, tail_pat, input, env) do
    case match_each(pre_pats, input, env) do
      {:ok, env2, rest_after_pre} ->
        match_after_pre(ell_pat, post_pats, tail_pat, rest_after_pre, env2)

      :no_match ->
        :no_match
    end
  end

  defp match_after_pre(ell_pat, post_pats, tail_pat, input, env) do
    {items, tail_input} = collect_proper(input)
    num_post = length(post_pats)
    num_items = length(items)

    if num_items < num_post do
      :no_match
    else
      {ell_items, post_items} = Enum.split(items, num_items - num_post)

      with {:ok, ell_bindings} <- match_ellipsis(ell_pat, ell_items),
           env2 <- merge_bindings(env, ell_bindings),
           rest_form <- list_with_tail(post_items, tail_input),
           {:ok, env3, leftover} <- match_each(post_pats, rest_form, env2),
           {:ok, env4} <- match(tail_pat, leftover, env3) do
        {:ok, env4}
      else
        _ -> :no_match
      end
    end
  end

  defp collect_proper([]), do: {[], []}

  defp collect_proper([h | t]) do
    {rest, tail} = collect_proper(t)
    {[h | rest], tail}
  end

  defp collect_proper(other), do: {[], other}

  defp list_with_tail([], tail), do: tail
  defp list_with_tail([h | t], tail), do: [h | list_with_tail(t, tail)]

  defp match_ellipsis(ell_pat, items) do
    pvars = collect_pvars(ell_pat, %{}) |> Map.keys()
    initial = Map.new(pvars, &{&1, []})

    items
    |> Enum.reduce_while({:ok, initial}, &accumulate_ellipsis_iter(&1, &2, ell_pat, pvars))
    |> finalise_ellipsis()
  end

  defp accumulate_ellipsis_iter(item, {:ok, acc}, ell_pat, pvars) do
    case match(ell_pat, item, %{}) do
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

  defp instantiate([], _env, _mark), do: []

  defp instantiate({:t_sym, name}, _env, mark) do
    if MapSet.member?(@core_keywords, name) do
      {:sym, name}
    else
      {:sym, mark_name(name, mark)}
    end
  end

  defp instantiate({:t_pvar, name, _depth}, env, _mark) do
    case Map.fetch(env, name) do
      {:ok, {:ellipsis_list, _}} ->
        raise Error, reason: {:bad_template, "pattern variable `#{name}` used outside ellipsis"}

      {:ok, value} ->
        value

      :error ->
        raise Error, reason: {:bad_template, "unbound pattern variable `#{name}`"}
    end
  end

  defp instantiate({:t_const, value}, _env, _mark), do: value

  defp instantiate({:t_quote, q_datum}, env, _mark) do
    [{:sym, "quote"} | [instantiate_quoted(q_datum, env) | []]]
  end

  defp instantiate({:t_list, items, tail}, env, mark) do
    head_forms = expand_template_items(items, env, mark)
    tail_form = instantiate(tail, env, mark)
    list_with_tail(head_forms, tail_form)
  end

  defp instantiate({:t_vector, items}, env, mark) do
    forms = expand_template_items(items, env, mark)
    {:vector, List.to_tuple(forms)}
  end

  defp instantiate_quoted(:q_null, _env), do: []
  defp instantiate_quoted({:q_sym, name}, _env), do: {:sym, name}
  defp instantiate_quoted({:q_const, v}, _env), do: v

  defp instantiate_quoted({:q_pvar, name, _depth}, env) do
    case Map.fetch(env, name) do
      {:ok, {:ellipsis_list, _}} ->
        raise Error,
          reason: {:bad_template, "pattern variable `#{name}` used outside ellipsis (in quote)"}

      {:ok, value} ->
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

  defp expand_template_items([], _env, _mark), do: []

  defp expand_template_items([{tmpl, 0} | rest], env, mark) do
    [instantiate(tmpl, env, mark) | expand_template_items(rest, env, mark)]
  end

  defp expand_template_items([{tmpl, n} | rest], env, mark) when n >= 1 do
    expand_ellipsis(tmpl, n, env, mark) ++ expand_template_items(rest, env, mark)
  end

  defp expand_ellipsis(tmpl, 0, env, mark), do: [instantiate(tmpl, env, mark)]

  defp expand_ellipsis(tmpl, n, env, mark) when n >= 1 do
    pvars_used = template_pvars_at_depth(tmpl, n)

    if pvars_used == [] do
      raise Error, reason: {:ellipsis_no_pattern_var, "template"}
    end

    pvars_used
    |> pvar_lists(env)
    |> validate_pvar_lengths(pvars_used)
    |> iterate_ellipsis(tmpl, n, env, mark, pvars_used)
  end

  # The driving pvars all have the same length (or we'd raise) and we
  # need O(N) total work per iteration count, not O(N²). Walk all
  # the bound `:ellipsis_list`s in lockstep, peeling one element off
  # each at every step and putting them into the sub-env. Termination
  # is by emptiness of the first list — `validate_pvar_lengths` has
  # already proved every list has the same length, so checking one
  # is enough.
  defp iterate_ellipsis([[] | _], _tmpl, _n, _env, _mark, _pvars), do: []
  defp iterate_ellipsis([], _tmpl, _n, _env, _mark, _pvars), do: []

  defp iterate_ellipsis(lists, tmpl, n, env, mark, pvars_used) do
    {heads, tails} = peel_lists(lists, [], [])
    sub_env = put_pvars(env, pvars_used, heads)

    expand_ellipsis(tmpl, n - 1, sub_env, mark) ++
      iterate_ellipsis(tails, tmpl, n, env, mark, pvars_used)
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
        {:ok, {:ellipsis_list, list}} -> list
        {:ok, _} -> raise Error, reason: {:bad_template, "pvar `#{name}` not under ellipsis"}
        :error -> raise Error, reason: {:bad_template, "pvar `#{name}` unbound"}
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

  # All template-side pattern variables of depth ≥ `min_depth`. Used to
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
