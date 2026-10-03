defmodule Schooner.Eval.Analyze do
  @moduledoc false

  # Pre-pass that rewrites the expander's core-form s-expressions into
  # a tagged intermediate representation, which `Schooner.Eval.compile/2`
  # turns into closures. Special-form dispatch, `parse_params/1` and
  # `desugar_body/1` run once here rather than each time a form is
  # evaluated, so creating a closure at run time is a tuple build.
  #
  # ## Lexical addressing
  #
  # Analysis threads a compile-time *scope* — a list of frames that
  # mirrors, one for one, the frames the evaluator pushes at run time:
  #
  #   * `{:pos, names}` for a closure's parameters and a `guard`
  #     handler's variable. The run-time frame is the tuple
  #     `{names_tuple, v1, v2, ...}`.
  #   * `{:rec, names}` for a `letrec*` frame. The run-time frame is a
  #     process-dictionary slot holding a values tuple.
  #
  # Each variable reference is resolved against that scope to
  #
  #   * `{:lref, depth, index}` — element `index` of the positional
  #     frame `depth` levels up;
  #   * `{:rref, depth, slot, name, fallback}` — slot `slot` of the
  #     recursive frame `depth` levels up. `fallback` is the same name
  #     resolved in the scope *below* that frame, used if the frame's
  #     slot has already been released (see `Schooner.Env`), which is
  #     where a by-name lookup would continue;
  #   * `{:gref, name, marked}` — a top-level binding. `marked` is the
  #     hygiene fallback: when `name` carries a macro mark and has no
  #     binding, the name with the mark stripped is used instead, so
  #     `marked` is that base name resolved against the full scope (or
  #     `nil` for an unmarked name).
  #
  # Top-level forms are analysed against the empty scope, so
  # `Eval.eval/2` and compiled programs must run against an env with no
  # lexical frames — which every caller does.
  #
  # ## Error timing
  #
  # A malformed core form must fail when (and only when) evaluation
  # reaches it: a bad form in an untaken branch is harmless, and
  # earlier top-level forms still run. So `analyze/1` never raises a
  # `Schooner.Eval.Error`; it replaces the offending node with
  # `{:raise, exception}`, which the evaluator raises on arrival. Each
  # node owns the errors from its own shape check, and children are
  # analysed independently, so the raise lands at the malformed node
  # rather than at an enclosing one.
  #
  # A `lambda` body that fails to desugar fails the `lambda` node, so
  # the error surfaces when the closure is created. Bodies that run
  # after other work (`letrec*` after its inits, `guard` inside its
  # handler extent) become a single `{:raise, exception}` body form so
  # that work still happens first.

  alias Schooner.Eval.Error
  alias Schooner.Expander.SyntaxRules
  alias Schooner.Value

  @type params ::
          {:fixed, non_neg_integer(), [binary()]}
          | {:any, binary()}
          | {:fixed_rest, non_neg_integer(), [binary()], binary()}

  @type scope :: [{:pos, %{binary() => pos_integer()}} | {:rec, %{binary() => non_neg_integer()}}]

  @type binding ::
          {:single, non_neg_integer(), ir()}
          | {:multi, params(), ir(), [non_neg_integer()]}

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

  @type ref ::
          {:lref, non_neg_integer(), pos_integer()}
          | {:rref, non_neg_integer(), non_neg_integer(), binary(), ref()}
          | {:gref, binary(), ref() | nil}

  @type ir ::
          {:const, Value.t()}
          | ref()
          | {:if, ir(), ir(), ir()}
          | {:app, ir(), [ir()]}
          | {:lambda, params(), {tuple(), [ir()]}, binary() | nil}
          | {:define, binary(), ir()}
          | {:define_values, params(), ir()}
          | {:seq, [ir()]}
          | {:letrec, [binary()], [binding()], [ir()]}
          | {:fixrec, [{tuple(), [ir()]}], [ir()]}
          | {:known_call, non_neg_integer(), non_neg_integer(), tuple(), [ir()]}
          | {:quasi, template()}
          | {:guard, {binary()}, [guard_clause()], [ir()]}
          | {:raise, Exception.t()}

  @doc false
  @spec analyze(Value.t()) :: ir()
  def analyze(form), do: analyze(form, [])

  @spec analyze(Value.t(), scope()) :: ir()
  defp analyze(form, scope) do
    analyze_form(form, scope)
  rescue
    e in Error -> {:raise, e}
  end

  defp analyze_form({:sym, name}, scope), do: resolve(name, scope)
  defp analyze_form([], _scope), do: raise(Error, reason: :empty_application)
  defp analyze_form([{:sym, "quote"} | tail], _scope), do: analyze_quote(tail)
  defp analyze_form([{:sym, "if"} | tail], scope), do: analyze_if(tail, scope)
  defp analyze_form([{:sym, "lambda"} | tail], scope), do: analyze_lambda(tail, scope)
  defp analyze_form([{:sym, "define"} | tail], scope), do: analyze_define(tail, scope)

  defp analyze_form([{:sym, "define-values"} | tail], scope),
    do: analyze_define_values(tail, scope)

  defp analyze_form([{:sym, "begin"} | tail], scope), do: {:seq, analyze_all(tail, scope)}
  defp analyze_form([{:sym, "letrec*"} | tail], scope), do: analyze_letrec_star(tail, scope)
  defp analyze_form([{:sym, "quasiquote"} | tail], scope), do: analyze_quasiquote(tail, scope)
  defp analyze_form([{:sym, "guard"} | tail], scope), do: analyze_guard(tail, scope)

  defp analyze_form([head | tail], scope),
    do: {:app, analyze(head, scope), analyze_args(tail, scope)}

  defp analyze_form(value, _scope), do: {:const, value}

  defp analyze_all(forms, scope), do: Enum.map(forms, &analyze(&1, scope))

  # The arguments before a non-list tail are still evaluated, so the
  # raise goes in the argument position after the last proper element.
  defp analyze_args([], _scope), do: []
  defp analyze_args([h | t], scope), do: [analyze(h, scope) | analyze_args(t, scope)]
  defp analyze_args(_, _scope), do: [{:raise, Error.exception(reason: :improper_application)}]

  # ---------------------------------------------------------------------------
  # Variable resolution
  # ---------------------------------------------------------------------------

  defp resolve(name, scope), do: resolve(name, scope, 0, scope, true)

  defp resolve(name, [], _depth, full, marked?) do
    {:gref, name, if(marked?, do: marked_fallback(name, full))}
  end

  defp resolve(name, [{:pos, slots} | rest], depth, full, marked?) do
    case slots do
      %{^name => index} -> {:lref, depth, index}
      _ -> resolve(name, rest, depth + 1, full, marked?)
    end
  end

  defp resolve(name, [{:rec, slots} | rest], depth, full, marked?) do
    case slots do
      %{^name => slot} ->
        {:rref, depth, slot, name, resolve(name, rest, depth + 1, full, marked?)}

      _ ->
        resolve(name, rest, depth + 1, full, marked?)
    end
  end

  # A name that carries a hygiene mark from a macro template but was
  # never bound by an introduced binder is a free reference to the
  # unmarked base name — usually a runtime primitive like `+`. The base
  # is looked up from the top of the scope, and does not itself get a
  # second marked fallback.
  defp marked_fallback(name, full) do
    case SyntaxRules.strip_mark(name) do
      {:ok, base} -> resolve(base, full, 0, full, false)
      _ -> nil
    end
  end

  # Positional frames hold their names in element 0, so values start at
  # element 1. A duplicated name resolves to its last occurrence, as a
  # map-built frame would.
  defp pos_frame(names) do
    slots = names |> Enum.with_index(1) |> Map.new()
    {{:pos, slots}, List.to_tuple(names)}
  end

  # ---------------------------------------------------------------------------
  # quote / if / lambda
  # ---------------------------------------------------------------------------

  defp analyze_quote([datum | []]), do: {:const, datum}
  defp analyze_quote(_), do: raise(Error, reason: {:bad_special_form, "quote"})

  defp analyze_if([test | [then_e | []]], scope) do
    {:if, analyze(test, scope), analyze(then_e, scope), {:const, :unspecified}}
  end

  defp analyze_if([test | [then_e | [else_e | []]]], scope) do
    {:if, analyze(test, scope), analyze(then_e, scope), analyze(else_e, scope)}
  end

  defp analyze_if(_, _scope), do: raise(Error, reason: {:bad_special_form, "if"})

  defp analyze_lambda([_params_form | []], _scope) do
    raise(Error, reason: {:bad_special_form, "lambda"})
  end

  defp analyze_lambda([params_form | body], scope), do: lambda(params_form, body, nil, scope)
  defp analyze_lambda(_, _scope), do: raise(Error, reason: {:bad_special_form, "lambda"})

  # The closure body carries the frame's names tuple alongside the
  # analysed forms so application can build the positional frame
  # without converting the parameter list each call.
  defp lambda(params_form, body, name, scope) do
    params = parse_params(params_form)
    {frame, names} = pos_frame(spec_names(params))
    {:lambda, params, {names, analyze_body(body, [frame | scope])}, name}
  end

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

  defp spec_names({:fixed, _, names}), do: names
  defp spec_names({:any, name}), do: [name]
  defp spec_names({:fixed_rest, _, names, rest}), do: names ++ [rest]

  # ---------------------------------------------------------------------------
  # define / define-values
  # ---------------------------------------------------------------------------

  defp analyze_define([{:sym, name} | [expr | []]], scope) do
    {:define, name, analyze(expr, scope)}
  end

  defp analyze_define([[{:sym, _name} | _params] | []], _scope) do
    raise(Error, reason: {:bad_special_form, "define"})
  end

  defp analyze_define([[{:sym, name} | params_form] | body], scope) do
    {:define, name, lambda(params_form, body, name, scope)}
  end

  defp analyze_define(_, _scope), do: raise(Error, reason: {:bad_special_form, "define"})

  defp analyze_define_values([formals | [expr | []]], scope) do
    {:define_values, parse_define_values_formals(formals), analyze(expr, scope)}
  end

  defp analyze_define_values(_, _scope),
    do: raise(Error, reason: {:bad_special_form, "define-values"})

  defp parse_define_values_formals(formals) do
    parse_params(formals)
  rescue
    Error -> reraise Error, [reason: {:bad_special_form, "define-values"}], __STACKTRACE__
  end

  # ---------------------------------------------------------------------------
  # letrec*
  # ---------------------------------------------------------------------------
  #
  # Shapes are checked and names collected before any init is analysed,
  # because the inits are analysed inside the new recursive frame. Each
  # distinct name gets one slot (first occurrence order, matching
  # `Env.extend_rec/2`); a binding records the slot(s) it writes.

  defp analyze_letrec_star([bindings_form | body], scope) when body != [] do
    parsed = parse_bindings(bindings_form, [])
    names = parsed |> Enum.flat_map(&binding_names/1) |> Enum.uniq()
    slots = names |> Enum.with_index() |> Map.new()
    rec_scope = [{:rec, slots} | scope]

    bindings =
      Enum.map(parsed, fn
        {:single, name, init} ->
          {:single, Map.fetch!(slots, name), analyze(init, rec_scope)}

        {:multi, spec, init} ->
          targets = Enum.map(spec_names(spec), &Map.fetch!(slots, &1))
          {:multi, spec, analyze(init, rec_scope), targets}
      end)

    known_calls({:letrec, names, bindings, analyze_deferred_body(body, rec_scope)})
  end

  defp analyze_letrec_star(_, _scope), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  # `letrec*` bindings are normally `(name init)`. The body desugarer
  # emits a second internal-only shape, `{:multi_vals, params_spec}`
  # in the head slot, to splice `define-values` into the rec frame
  # without mutation: one init expression produces a value list whose
  # elements are bound across multiple rec slots in a single step.
  # The Elixir-tagged head is unreachable from Scheme source, so the
  # surface `letrec*` syntax is unchanged.
  defp parse_bindings([], acc), do: Enum.reverse(acc)

  defp parse_bindings([[{:sym, name} | [init | []]] | rest], acc) do
    parse_bindings(rest, [{:single, name, init} | acc])
  end

  defp parse_bindings([[{:multi_vals, spec} | [init | []]] | rest], acc) do
    parse_bindings(rest, [{:multi, spec, init} | acc])
  end

  defp parse_bindings(_, _), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  defp binding_names({:single, name, _}), do: [name]
  defp binding_names({:multi, spec, _}), do: spec_names(spec)

  # ---------------------------------------------------------------------------
  # Known calls
  # ---------------------------------------------------------------------------
  #
  # A `letrec*` whose bindings are all fixed-arity lambdas, and whose
  # names are only ever used as the operator of a call with the right
  # number of arguments, can never let one of those lambdas be observed
  # as a value: nothing takes it, stores it, compares it or returns it.
  # Named `let` is the common case. Such a `letrec*` becomes
  #
  #     {:fixrec, [{names_tuple, body}, ...], body}
  #
  # and each call to one of its lambdas becomes
  #
  #     {:known_call, depth, slot, names_tuple, args}
  #
  # which the evaluator runs by pushing the callee's argument frame and
  # tail-calling its compiled body, with no closure, process-dictionary
  # frame, lookup or arity check.
  #
  # A call from inside a nested `lambda` disqualifies the `letrec*`:
  # that closure can outlive the form, and calling it later must still
  # see the released-frame lookup `Schooner.Env` describes. Calls from
  # inside a nested `:fixrec` lambda are fine, since it is never a
  # closure either; this is what lets nested named `let` loops both
  # convert. Analysis runs bottom-up, so inner forms have already been
  # converted by the time an outer one is checked.
  #
  # Every lambda init evaluates without effects and every reference is
  # a call, so no init can observe an uninitialised slot and the
  # conversion keeps evaluation order and error timing unchanged.

  defp known_calls({:letrec, names, bindings, body} = node) do
    case known_arities(bindings, 0, []) do
      {:ok, arities} when length(arities) == length(names) ->
        info = List.to_tuple(arities)

        try do
          lambdas =
            for {:single, _slot, {:lambda, _params, {fnames, fbody}, _name}} <- bindings do
              {fnames, known_all(fbody, 1, false, info)}
            end

          {:fixrec, lambdas, known_all(body, 0, false, info)}
        catch
          :not_known -> node
        end

      _ ->
        node
    end
  end

  # Slot `i` must be written by binding `i`, so the frame's lambdas
  # line up with their slots.
  defp known_arities([], _i, acc), do: {:ok, Enum.reverse(acc)}

  defp known_arities([{:single, i, {:lambda, {:fixed, n, _}, {fnames, _}, _}} | rest], i, acc),
    do: known_arities(rest, i + 1, [{n, fnames} | acc])

  defp known_arities(_bindings, _i, _acc), do: :error

  # Rewrite calls to the candidate frame `d` levels up, throwing
  # `:not_known` at any other use of it. `lam?` is true under a nested
  # `lambda`. Depths in a `rref`'s or marked `gref`'s fallback are
  # counted from the same scope as the reference itself.
  defp known_all(irs, d, lam?, info), do: Enum.map(irs, &known(&1, d, lam?, info))

  defp known({:app, {:rref, d, slot, _name, _fallback}, args}, d, false, info) do
    {n, fnames} = elem(info, slot)
    if length(args) != n, do: throw(:not_known)
    {:known_call, d, slot, fnames, known_all(args, d, false, info)}
  end

  defp known({:rref, d, _slot, _name, _fallback}, d, _lam?, _info), do: throw(:not_known)

  defp known({:rref, depth, slot, name, fallback}, d, lam?, info),
    do: {:rref, depth, slot, name, known(fallback, d, lam?, info)}

  defp known({:gref, _name, nil} = ref, _d, _lam?, _info), do: ref

  defp known({:gref, name, marked}, d, lam?, info),
    do: {:gref, name, known(marked, d, lam?, info)}

  defp known({tag, _} = leaf, _d, _lam?, _info) when tag in [:const, :raise], do: leaf
  defp known({:lref, _, _} = ref, _d, _lam?, _info), do: ref

  defp known({:if, test, then_e, else_e}, d, lam?, info),
    do:
      {:if, known(test, d, lam?, info), known(then_e, d, lam?, info),
       known(else_e, d, lam?, info)}

  defp known({:app, head, args}, d, lam?, info),
    do: {:app, known(head, d, lam?, info), known_all(args, d, lam?, info)}

  defp known({:known_call, depth, slot, fnames, args}, d, lam?, info),
    do: {:known_call, depth, slot, fnames, known_all(args, d, lam?, info)}

  defp known({:lambda, params, {fnames, body}, name}, d, _lam?, info),
    do: {:lambda, params, {fnames, known_all(body, d + 1, true, info)}, name}

  defp known({:define, name, expr}, d, lam?, info),
    do: {:define, name, known(expr, d, lam?, info)}

  defp known({:define_values, spec, expr}, d, lam?, info),
    do: {:define_values, spec, known(expr, d, lam?, info)}

  defp known({:seq, body}, d, lam?, info), do: {:seq, known_all(body, d, lam?, info)}

  defp known({:letrec, names, bindings, body}, d, lam?, info) do
    bindings =
      Enum.map(bindings, fn
        {:single, slot, init} -> {:single, slot, known(init, d + 1, lam?, info)}
        {:multi, spec, init, slots} -> {:multi, spec, known(init, d + 1, lam?, info), slots}
      end)

    {:letrec, names, bindings, known_all(body, d + 1, lam?, info)}
  end

  defp known({:fixrec, lambdas, body}, d, lam?, info) do
    lambdas = for {fnames, fbody} <- lambdas, do: {fnames, known_all(fbody, d + 2, lam?, info)}
    {:fixrec, lambdas, known_all(body, d + 1, lam?, info)}
  end

  defp known({:quasi, template}, d, lam?, info),
    do: {:quasi, known_template(template, d, lam?, info)}

  defp known({:guard, names, clauses, body}, d, lam?, info) do
    clauses = Enum.map(clauses, &known_clause(&1, d + 1, lam?, info))
    {:guard, names, clauses, known_all(body, d, lam?, info)}
  end

  defp known_template({:qc, _} = t, _d, _lam?, _info), do: t
  defp known_template({:qu, expr}, d, lam?, info), do: {:qu, known(expr, d, lam?, info)}

  defp known_template({:qcons, h, t}, d, lam?, info),
    do: {:qcons, known_template(h, d, lam?, info), known_template(t, d, lam?, info)}

  defp known_template({:qsplice, expr, t}, d, lam?, info),
    do: {:qsplice, known(expr, d, lam?, info), known_template(t, d, lam?, info)}

  defp known_template({:qvec, t}, d, lam?, info), do: {:qvec, known_template(t, d, lam?, info)}

  defp known_clause({:else, body}, d, lam?, info), do: {:else, known_all(body, d, lam?, info)}
  defp known_clause({:bad, _} = bad, _d, _lam?, _info), do: bad
  defp known_clause({:test, test}, d, lam?, info), do: {:test, known(test, d, lam?, info)}

  defp known_clause({:arrow, test, proc}, d, lam?, info),
    do: {:arrow, known(test, d, lam?, info), known(proc, d, lam?, info)}

  defp known_clause({:test_body, test, body}, d, lam?, info),
    do: {:test_body, known(test, d, lam?, info), known_all(body, d, lam?, info)}

  # ---------------------------------------------------------------------------
  # quasiquote
  # ---------------------------------------------------------------------------
  #
  # The template is compiled into a small tree whose fully-constant
  # subtrees fold to `{:qc, datum}`, so a quasiquote with few unquotes
  # rebuilds only the spine leading to them. `unquote` and
  # `unquote-splicing` only fire at quasi level 1; nested `quasiquote`
  # raises the level, nested `unquote` lowers it.

  defp analyze_quasiquote([datum | []], scope), do: {:quasi, template(datum, 1, scope)}

  defp analyze_quasiquote(_, _scope),
    do: raise(Error, reason: {:bad_special_form, "quasiquote"})

  defp template([{:sym, "unquote"} | [expr | []]], 1, scope), do: {:qu, analyze(expr, scope)}

  defp template([{:sym, "unquote"} | [expr | []]], n, scope) when n > 1 do
    qlist([{:qc, Value.symbol("unquote")}, template(expr, n - 1, scope)])
  end

  defp template([{:sym, "quasiquote"} | [expr | []]], n, scope) do
    qlist([{:qc, Value.symbol("quasiquote")}, template(expr, n + 1, scope)])
  end

  defp template([head | tail], level, scope) do
    case head do
      [{:sym, "unquote-splicing"} | [expr | []]] when level == 1 ->
        {:qsplice, analyze(expr, scope), template(tail, level, scope)}

      _ ->
        qcons(template(head, level, scope), template(tail, level, scope))
    end
  end

  defp template({:vector, t}, level, scope) do
    case template(Value.list(Tuple.to_list(t)), level, scope) do
      {:qc, list} -> {:qc, Value.vector(list)}
      other -> {:qvec, other}
    end
  end

  defp template(other, _level, _scope), do: {:qc, other}

  defp qlist([]), do: {:qc, []}
  defp qlist([h | t]), do: qcons(h, qlist(t))

  defp qcons({:qc, h}, {:qc, t}), do: {:qc, [h | t]}
  defp qcons(h, t), do: {:qcons, h, t}

  # ---------------------------------------------------------------------------
  # guard
  # ---------------------------------------------------------------------------
  #
  # Clauses keep their source order. A malformed clause (or improper
  # clause list) becomes a `{:bad, exception}` entry that raises only
  # if the clause walk reaches it, and an `else` clause ends the list
  # since nothing after it is ever inspected. The body runs in the
  # guard's own scope; the clauses run in a one-slot frame binding the
  # condition variable.

  defp analyze_guard([[{:sym, var} | clauses_form] | body], scope)
       when is_binary(var) and body != [] do
    {frame, names} = pos_frame([var])
    clauses = guard_clauses(clauses_form, [frame | scope])
    {:guard, names, clauses, analyze_deferred_body(body, scope)}
  end

  defp analyze_guard(_, _scope), do: raise(Error, reason: {:bad_special_form, "guard"})

  defp guard_clauses([], _scope), do: []

  defp guard_clauses([[{:sym, "else"} | body] | _rest], scope) when body != [] do
    [{:else, analyze_deferred_body(body, scope)}]
  end

  defp guard_clauses([clause | rest], scope),
    do: [guard_clause(clause, scope) | guard_clauses(rest, scope)]

  defp guard_clauses(_, _scope), do: [bad_guard()]

  defp guard_clause([test | []], scope), do: {:test, analyze(test, scope)}

  defp guard_clause([test | [{:sym, "=>"} | [proc_expr | []]]], scope) do
    {:arrow, analyze(test, scope), analyze(proc_expr, scope)}
  end

  defp guard_clause([test | body], scope) when body != [] do
    {:test_body, analyze(test, scope), analyze_deferred_body(body, scope)}
  end

  defp guard_clause(_, _scope), do: bad_guard()

  defp bad_guard, do: {:bad, Error.exception(reason: {:bad_special_form, "guard"})}

  # ---------------------------------------------------------------------------
  # Bodies
  # ---------------------------------------------------------------------------

  # Desugaring errors in this body fail the enclosing node (lambda,
  # define-fn), so they surface when the closure is created.
  defp analyze_body(body, scope), do: body |> desugar_body() |> analyze_all(scope)

  # A body whose desugaring errors surface only once the body runs.
  defp analyze_deferred_body(body, scope) do
    analyze_body(body, scope)
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

  # Emits the internal `{:multi_vals, spec}` binding head described at
  # `parse_bindings/2`.
  defp build_letrec_bindings([{:multi, spec, init} | rest]) do
    binding = [{:multi_vals, spec} | [init | []]]
    [binding | build_letrec_bindings(rest)]
  end
end
