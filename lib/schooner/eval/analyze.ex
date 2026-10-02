defmodule Schooner.Eval.Analyze do
  @moduledoc false

  # Pre-pass that rewrites the expander's core-form s-expressions into
  # a tagged intermediate representation for `Schooner.Eval.exec/2`.
  #
  # The evaluator used to dispatch on the raw s-expression at every
  # step — matching `{:sym, "if"}`, `{:sym, "lambda"}`, … against each
  # application head — and re-ran `parse_params/1` and
  # `desugar_body/1` every time a `lambda` was evaluated. Doing that
  # work once here leaves `exec/2` with a single atom-tag dispatch per
  # node and makes closure creation a tuple build.
  #
  # ## Error timing
  #
  # A malformed core form must fail when (and only when) evaluation
  # reaches it, exactly as it did before this pass existed: a bad form
  # in an untaken branch is harmless, and earlier top-level forms still
  # run. So `analyze/1` never raises a `Schooner.Eval.Error`; it
  # replaces the offending node with `{:raise, exception}`, which
  # `exec/2` raises on arrival. Each node owns the errors its own shape
  # check would have raised, and children are analysed independently,
  # so the raise lands at the same position the old evaluator would
  # have raised from.
  #
  # Bodies whose `desugar_body/1` ran at closure-creation time (lambda)
  # fail the `lambda` node; bodies desugared after other work had
  # already happened (`letrec*` after its inits, `guard` inside its
  # handler extent) become a single `{:raise, exception}` body form so
  # the earlier work still happens first.

  alias Schooner.Eval.Error
  alias Schooner.Value

  @type params ::
          {:fixed, non_neg_integer(), [binary()]}
          | {:any, binary()}
          | {:fixed_rest, non_neg_integer(), [binary()], binary()}

  @type binding :: {:single, binary(), ir()} | {:multi, params(), ir()}

  @type guard_clause ::
          {:else, [ir()]}
          | {:test, ir()}
          | {:arrow, ir(), ir()}
          | {:test_body, ir(), [ir()]}
          | {:bad, Exception.t()}

  @type template ::
          {:qc, Value.t()}
          | {:qu, ir()}
          | {:qcons, template(), template()}
          | {:qsplice, ir(), template()}
          | {:qvec, template()}

  @type ir ::
          {:const, Value.t()}
          | {:ref, binary()}
          | {:if, ir(), ir(), ir()}
          | {:app, ir(), [ir()]}
          | {:lambda, params(), [ir()], binary() | nil}
          | {:define, binary(), ir()}
          | {:define_values, params(), ir()}
          | {:seq, [ir()]}
          | {:letrec, [binary()], [binding()], [ir()]}
          | {:quasi, template()}
          | {:guard, binary(), [guard_clause()], [ir()]}
          | {:raise, Exception.t()}

  @doc false
  @spec analyze(Value.t()) :: ir()
  def analyze(form) do
    analyze_form(form)
  rescue
    e in Error -> {:raise, e}
  end

  defp analyze_form({:sym, name}), do: {:ref, name}
  defp analyze_form([]), do: raise(Error, reason: :empty_application)
  defp analyze_form([{:sym, "quote"} | tail]), do: analyze_quote(tail)
  defp analyze_form([{:sym, "if"} | tail]), do: analyze_if(tail)
  defp analyze_form([{:sym, "lambda"} | tail]), do: analyze_lambda(tail)
  defp analyze_form([{:sym, "define"} | tail]), do: analyze_define(tail)
  defp analyze_form([{:sym, "define-values"} | tail]), do: analyze_define_values(tail)
  defp analyze_form([{:sym, "begin"} | tail]), do: {:seq, Enum.map(tail, &analyze/1)}
  defp analyze_form([{:sym, "letrec*"} | tail]), do: analyze_letrec_star(tail)
  defp analyze_form([{:sym, "quasiquote"} | tail]), do: analyze_quasiquote(tail)
  defp analyze_form([{:sym, "guard"} | tail]), do: analyze_guard(tail)
  defp analyze_form([head | tail]), do: {:app, analyze(head), analyze_args(tail)}
  defp analyze_form(value), do: {:const, value}

  # The old evaluator evaluated each argument and only then tripped on
  # a non-list tail, so the raise goes in the argument position after
  # the last proper element.
  defp analyze_args([]), do: []
  defp analyze_args([h | t]), do: [analyze(h) | analyze_args(t)]
  defp analyze_args(_), do: [{:raise, Error.exception(reason: :improper_application)}]

  # ---------------------------------------------------------------------------
  # quote / if / lambda
  # ---------------------------------------------------------------------------

  defp analyze_quote([datum | []]), do: {:const, datum}
  defp analyze_quote(_), do: raise(Error, reason: {:bad_special_form, "quote"})

  defp analyze_if([test | [then_e | []]]) do
    {:if, analyze(test), analyze(then_e), {:const, :unspecified}}
  end

  defp analyze_if([test | [then_e | [else_e | []]]]) do
    {:if, analyze(test), analyze(then_e), analyze(else_e)}
  end

  defp analyze_if(_), do: raise(Error, reason: {:bad_special_form, "if"})

  defp analyze_lambda([_params_form | []]) do
    raise(Error, reason: {:bad_special_form, "lambda"})
  end

  defp analyze_lambda([params_form | body]) do
    {:lambda, parse_params(params_form), analyze_body(body), nil}
  end

  defp analyze_lambda(_), do: raise(Error, reason: {:bad_special_form, "lambda"})

  defp parse_params({:sym, name}), do: {:any, name}
  defp parse_params([]), do: {:fixed, 0, []}
  defp parse_params([_ | _] = list), do: collect_params(list, [], 0)
  defp parse_params(_), do: raise(Error, reason: :invalid_params)

  defp collect_params([], acc, n), do: {:fixed, n, Enum.reverse(acc)}

  defp collect_params({:sym, rest_name}, acc, n) do
    {:fixed_rest, n, Enum.reverse(acc), rest_name}
  end

  defp collect_params([{:sym, name} | t], acc, n) do
    collect_params(t, [name | acc], n + 1)
  end

  defp collect_params(_, _, _), do: raise(Error, reason: :invalid_params)

  # ---------------------------------------------------------------------------
  # define / define-values
  # ---------------------------------------------------------------------------

  defp analyze_define([{:sym, name} | [expr | []]]), do: {:define, name, analyze(expr)}

  defp analyze_define([[{:sym, _name} | _params] | []]) do
    raise(Error, reason: {:bad_special_form, "define"})
  end

  defp analyze_define([[{:sym, name} | params_form] | body]) do
    {:define, name, {:lambda, parse_params(params_form), analyze_body(body), name}}
  end

  defp analyze_define(_), do: raise(Error, reason: {:bad_special_form, "define"})

  defp analyze_define_values([formals | [expr | []]]) do
    {:define_values, parse_define_values_formals(formals), analyze(expr)}
  end

  defp analyze_define_values(_), do: raise(Error, reason: {:bad_special_form, "define-values"})

  defp parse_define_values_formals(formals) do
    parse_params(formals)
  rescue
    Error -> reraise Error, [reason: {:bad_special_form, "define-values"}], __STACKTRACE__
  end

  # ---------------------------------------------------------------------------
  # letrec*
  # ---------------------------------------------------------------------------

  defp analyze_letrec_star([bindings_form | body]) when body != [] do
    parsed = parse_bindings(bindings_form, [])
    {:letrec, collect_binding_names(parsed), parsed, analyze_deferred_body(body)}
  end

  defp analyze_letrec_star(_), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  # `letrec*` bindings are normally `(name init)`. The body desugarer
  # emits a second internal-only shape, `{:multi_vals, params_spec}`
  # in the head slot, to splice `define-values` into the rec frame
  # without mutation: one init expression produces a value list whose
  # elements are bound across multiple rec slots in a single step.
  # The Elixir-tagged head is unreachable from Scheme source, so the
  # surface `letrec*` syntax is unchanged.
  defp parse_bindings([], acc), do: Enum.reverse(acc)

  defp parse_bindings([[{:sym, name} | [init | []]] | rest], acc) do
    parse_bindings(rest, [{:single, name, analyze(init)} | acc])
  end

  defp parse_bindings([[{:multi_vals, spec} | [init | []]] | rest], acc) do
    parse_bindings(rest, [{:multi, spec, analyze(init)} | acc])
  end

  defp parse_bindings(_, _), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  defp collect_binding_names(parsed) do
    Enum.flat_map(parsed, fn
      {:single, name, _} -> [name]
      {:multi, spec, _} -> spec_names(spec)
    end)
  end

  defp spec_names({:fixed, _, names}), do: names
  defp spec_names({:any, name}), do: [name]
  defp spec_names({:fixed_rest, _, names, rest}), do: names ++ [rest]

  # ---------------------------------------------------------------------------
  # quasiquote
  # ---------------------------------------------------------------------------
  #
  # The template is compiled into a small tree whose fully-constant
  # subtrees fold to `{:qc, datum}`, so a quasiquote with few unquotes
  # rebuilds only the spine leading to them. `unquote` and
  # `unquote-splicing` only fire at quasi level 1; nested `quasiquote`
  # raises the level, nested `unquote` lowers it.

  defp analyze_quasiquote([datum | []]), do: {:quasi, template(datum, 1)}
  defp analyze_quasiquote(_), do: raise(Error, reason: {:bad_special_form, "quasiquote"})

  defp template([{:sym, "unquote"} | [expr | []]], 1), do: {:qu, analyze(expr)}

  defp template([{:sym, "unquote"} | [expr | []]], n) when n > 1 do
    qlist([{:qc, Value.symbol("unquote")}, template(expr, n - 1)])
  end

  defp template([{:sym, "quasiquote"} | [expr | []]], n) do
    qlist([{:qc, Value.symbol("quasiquote")}, template(expr, n + 1)])
  end

  defp template([head | tail], level) do
    case head do
      [{:sym, "unquote-splicing"} | [expr | []]] when level == 1 ->
        {:qsplice, analyze(expr), template(tail, level)}

      _ ->
        qcons(template(head, level), template(tail, level))
    end
  end

  defp template({:vector, t}, level) do
    case template(Value.list(Tuple.to_list(t)), level) do
      {:qc, list} -> {:qc, Value.vector(list)}
      other -> {:qvec, other}
    end
  end

  defp template(other, _level), do: {:qc, other}

  defp qlist([]), do: {:qc, []}
  defp qlist([h | t]), do: qcons(h, qlist(t))

  defp qcons({:qc, h}, {:qc, t}), do: {:qc, [h | t]}
  defp qcons(h, t), do: {:qcons, h, t}

  # ---------------------------------------------------------------------------
  # guard
  # ---------------------------------------------------------------------------
  #
  # Clauses are analysed in the same order the old evaluator matched
  # them. A malformed clause (or improper clause list) becomes a
  # `{:bad, exception}` entry that raises only if the clause walk
  # reaches it, and an `else` clause ends the list since nothing after
  # it was ever inspected.

  defp analyze_guard([[{:sym, var} | clauses_form] | body]) when is_binary(var) and body != [] do
    {:guard, var, guard_clauses(clauses_form), analyze_deferred_body(body)}
  end

  defp analyze_guard(_), do: raise(Error, reason: {:bad_special_form, "guard"})

  defp guard_clauses([]), do: []

  defp guard_clauses([[{:sym, "else"} | body] | _rest]) when body != [] do
    [{:else, analyze_deferred_body(body)}]
  end

  defp guard_clauses([clause | rest]), do: [guard_clause(clause) | guard_clauses(rest)]
  defp guard_clauses(_), do: [bad_guard()]

  defp guard_clause([test | []]), do: {:test, analyze(test)}

  defp guard_clause([test | [{:sym, "=>"} | [proc_expr | []]]]) do
    {:arrow, analyze(test), analyze(proc_expr)}
  end

  defp guard_clause([test | body]) when body != [] do
    {:test_body, analyze(test), analyze_deferred_body(body)}
  end

  defp guard_clause(_), do: bad_guard()

  defp bad_guard, do: {:bad, Error.exception(reason: {:bad_special_form, "guard"})}

  # ---------------------------------------------------------------------------
  # Bodies
  # ---------------------------------------------------------------------------

  # A body whose desugaring errors fail the enclosing node (lambda,
  # define-fn): the old evaluator desugared these at closure creation.
  defp analyze_body(body), do: body |> desugar_body() |> Enum.map(&analyze/1)

  # A body whose desugaring errors surface only once the body runs.
  defp analyze_deferred_body(body) do
    analyze_body(body)
  rescue
    e in Error -> [{:raise, e}]
  end

  # r7rs §5.3.3 lets a body begin with a sequence of `define` forms
  # followed by a sequence of expressions; the defines splice into a
  # `letrec*` whose body is the rest of the forms. `desugar_body/1`
  # performs that rewrite. Forms with no leading defines are returned
  # unchanged.
  #
  # `define` after a non-define form in the same body is a syntax
  # error, raised here rather than at evaluation time so the whole
  # body is rejected before any side-effecting init runs.
  defp desugar_body([]), do: []

  defp desugar_body(body) do
    case scan_defines(body, []) do
      {[], _rest} ->
        body

      {_defs, []} ->
        raise(Error, reason: :empty_body)

      {defs, rest} ->
        bindings = build_letrec_bindings(defs)
        letrec_form = [{:sym, "letrec*"} | [bindings | rest]]
        [letrec_form | []]
    end
  end

  defp scan_defines([], acc), do: {Enum.reverse(acc), []}

  # r7rs §5.3.3: a `(begin <form> ...)` at the head of a body is
  # spliced into the body in place. This is what lets
  # `define-record-type` work in an internal-definition position —
  # the expander emits a `(begin (define ...) (define ...) ...)`
  # for each record type and the splicing here makes those defines
  # behave as if they were written at the body level directly.
  defp scan_defines([[{:sym, "begin"} | inner] | rest], acc) do
    scan_defines(splice_begin(inner, rest), acc)
  end

  defp scan_defines([form | rest], acc) do
    case parse_internal_define(form) do
      nil ->
        check_no_more_defines(rest)
        {Enum.reverse(acc), [form | rest]}

      binding ->
        scan_defines(rest, [binding | acc])
    end
  end

  defp parse_internal_define([{:sym, "define"} | body]) do
    case body do
      [{:sym, name} | [expr | []]] ->
        {:single, name, expr}

      [[{:sym, name} | params] | body_forms] when body_forms != [] ->
        {:single, name, [{:sym, "lambda"} | [params | body_forms]]}

      _ ->
        raise(Error, reason: {:bad_special_form, "define"})
    end
  end

  # r7rs §5.3.2: `define-values` in internal-definition position fans
  # out into a single multi-binding letrec* slot. The producer is
  # evaluated once, and its values are spread across the formals'
  # rec slots in lock-step — no mutation, no auxiliary tmp visible to
  # the user.
  defp parse_internal_define([{:sym, "define-values"} | body]) do
    case body do
      [formals | [expr | []]] ->
        {:multi, parse_define_values_formals(formals), expr}

      _ ->
        raise(Error, reason: {:bad_special_form, "define-values"})
    end
  end

  defp parse_internal_define(_), do: nil

  defp check_no_more_defines([]), do: :ok

  defp check_no_more_defines([[{:sym, "begin"} | inner] | rest]) do
    check_no_more_defines(splice_begin(inner, rest))
  end

  defp check_no_more_defines([form | rest]) do
    if parse_internal_define(form) != nil do
      raise(Error, reason: :define_after_expression)
    else
      check_no_more_defines(rest)
    end
  end

  defp splice_begin([], rest), do: rest
  defp splice_begin([h | t], rest), do: [h | splice_begin(t, rest)]
  defp splice_begin(_, _), do: raise(Error, reason: {:bad_special_form, "begin"})

  defp build_letrec_bindings([]), do: []

  defp build_letrec_bindings([{:single, name, init} | rest]) do
    binding = [{:sym, name} | [init | []]]
    [binding | build_letrec_bindings(rest)]
  end

  # The `{:multi_vals, spec}` head is an Elixir-tagged tuple — Scheme
  # source can't construct it, so users typing into `letrec*` directly
  # never collide with this internal binding shape; only the desugarer
  # emits it. `parse_bindings/2` recognises it and routes the init
  # through the evaluator's multi-value binding path.
  defp build_letrec_bindings([{:multi, spec, init} | rest]) do
    binding = [{:multi_vals, spec} | [init | []]]
    [binding | build_letrec_bindings(rest)]
  end
end
