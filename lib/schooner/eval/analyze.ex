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
  #     process-dictionary slot holding a values tuple. Initializers that
  #     only reference earlier bindings can instead use a positional frame.
  #
  # Each variable reference is resolved against that scope to
  #
  #   * `{:lref, depth, index}` — element `index` of the positional
  #     frame `depth` levels up;
  #   * `{:rref, depth, slot, name, fallback, pos}` — slot `slot` of the
  #     recursive frame `depth` levels up. `fallback` is the same name
  #     resolved in the scope *below* that frame, used if the frame's
  #     slot has already been released (see `Schooner.Env`), which is
  #     where a by-name lookup would continue;
  #   * `{:gref, name, marked, pos}` — a top-level binding. `marked` is the
  #     hygiene fallback: when `name` carries a macro mark and has no
  #     binding, the name with the mark stripped is used instead, so
  #     `marked` is that base name resolved against the full scope (or
  #     `nil` for an unmarked name).
  #
  # ## Positions
  #
  # `analyze/2` walks the form's `Schooner.Reader` position tree beside
  # it (`nil` when there is none). Applications and variable references
  # record the `{line, column}` they start at as their last element, and
  # an analysis error is given the location of the innermost positioned
  # node, so a `{:raise, exception}` carries its own location. The IR
  # holds no file name: `Schooner.Eval.compile/3` adds it.
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
  alias Schooner.Expander.Positions, as: Pos
  alias Schooner.Expander.SyntaxRules
  alias Schooner.Lexer
  alias Schooner.Location
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
          | {:arrow, ir(), ir(), pos()}
          | {:test_body, ir(), [ir()]}
          | {:bad, Exception.t()}

  @type template ::
          {:qc, Value.t()}
          | {:qu, ir()}
          | {:qcons, template(), template()}
          | {:qsplice, ir(), template()}
          | {:qvec, template()}

  @type pos :: Lexer.position() | nil

  @type ref ::
          {:lref, non_neg_integer(), pos_integer()}
          | {:rref, non_neg_integer(), non_neg_integer(), binary(), ref(), pos()}
          | {:gref, binary(), ref() | nil, pos()}

  @type ir ::
          {:const, Value.t()}
          | ref()
          | {:if, ir(), ir(), ir()}
          | {:app, ir(), [ir()], pos()}
          | {:lambda, params(), {tuple(), [ir()]}, binary() | nil}
          | {:define, binary(), ir()}
          | {:define_values, params(), ir()}
          | {:seq, [ir()]}
          | {:letrec, [binary()], [binding()], [ir()]}
          | {:letseq, tuple(), [binding()], [ir()]}
          | {:fixrec, [{tuple(), [ir()]}], [ir()]}
          | {:known_call, non_neg_integer(), non_neg_integer(), tuple(), [ir()]}
          | {:quasi, template()}
          | {:guard, {binary()}, [guard_clause()], [ir()]}
          | {:raise, Exception.t()}

  # Local, inlined copies of the `Positions` walkers: they run for
  # every node analysed.
  @compile {:inline, car: 1, cdr: 1, at: 1, nth: 2}
  defp car({:pair, _, car, _}), do: car
  defp car(_), do: nil
  defp cdr({:pair, _, _, cdr}), do: cdr
  defp cdr(_), do: nil
  defp at({:pair, pos, _, _}), do: pos
  defp at({:atom, pos}), do: pos
  defp at(tree), do: Pos.at(tree)
  defp nth(t, 1), do: car(cdr(t))
  defp nth(t, 2), do: car(cdr(cdr(t)))
  defp nth(t, n), do: Pos.nth(t, n)

  @doc false
  @spec analyze(Value.t(), Pos.t()) :: ir()
  def analyze(form, tree \\ nil), do: analyze(form, tree, [])

  @spec analyze(Value.t(), Pos.t(), scope()) :: ir()
  defp analyze(form, t, scope) do
    analyze_form(form, t, scope)
  rescue
    e in Error -> {:raise, locate(e, t)}
  end

  defp locate(e, t), do: Location.attach(e, Location.new(nil, at(t)))

  defp analyze_form({:sym, name}, t, scope), do: resolve(name, scope, at(t))
  defp analyze_form([], _t, _scope), do: raise(Error, reason: :empty_application)
  defp analyze_form([{:sym, "quote"} | tail], _t, _scope), do: analyze_quote(tail)
  defp analyze_form([{:sym, "if"} | tail], t, scope), do: analyze_if(tail, t, scope)
  defp analyze_form([{:sym, "lambda"} | tail], t, scope), do: analyze_lambda(tail, t, scope)
  defp analyze_form([{:sym, "define"} | tail], t, scope), do: analyze_define(tail, t, scope)

  defp analyze_form([{:sym, "define-values"} | tail], t, scope),
    do: analyze_define_values(tail, t, scope)

  defp analyze_form([{:sym, "begin"} | tail], t, scope),
    do: {:seq, analyze_args(tail, cdr(t), scope)}

  defp analyze_form([{:sym, "letrec*"} | tail], t, scope),
    do: analyze_letrec_star(tail, t, scope)

  defp analyze_form([{:sym, "quasiquote"} | tail], t, scope),
    do: analyze_quasiquote(tail, t, scope)

  defp analyze_form([{:sym, "guard"} | tail], t, scope), do: analyze_guard(tail, t, scope)

  defp analyze_form([head | tail], t, scope),
    do: {:app, analyze(head, car(t), scope), analyze_args(tail, cdr(t), scope), at(t)}

  defp analyze_form(value, _t, _scope), do: {:const, value}

  # The arguments before a non-list tail are still evaluated, so the
  # raise goes in the argument position after the last proper element.
  defp analyze_args([], _t, _scope), do: []

  defp analyze_args([h | rest], t, scope),
    do: [analyze(h, car(t), scope) | analyze_args(rest, cdr(t), scope)]

  defp analyze_args(_, t, _scope),
    do: [{:raise, locate(Error.exception(reason: :improper_application), t)}]

  # Pair each element of the proper list `forms` with its tree from the
  # list's spine tree `t`.
  defp with_trees([], _t), do: []
  defp with_trees([h | rest], t), do: [{h, car(t)} | with_trees(rest, cdr(t))]
  defp with_trees(_, _t), do: raise(Error, reason: {:bad_special_form, "body"})

  # ---------------------------------------------------------------------------
  # Variable resolution
  # ---------------------------------------------------------------------------

  defp resolve(name, scope, pos), do: resolve(name, scope, 0, scope, true, pos)

  defp resolve(name, [], _depth, full, marked?, pos) do
    {:gref, name, if(marked?, do: marked_fallback(name, full, pos)), pos}
  end

  defp resolve(name, [{:pos, slots} | rest], depth, full, marked?, pos) do
    case slots do
      %{^name => index} -> {:lref, depth, index}
      _ -> resolve(name, rest, depth + 1, full, marked?, pos)
    end
  end

  defp resolve(name, [{:rec, slots} | rest], depth, full, marked?, pos) do
    case slots do
      %{^name => slot} ->
        {:rref, depth, slot, name, resolve(name, rest, depth + 1, full, marked?, pos), pos}

      _ ->
        resolve(name, rest, depth + 1, full, marked?, pos)
    end
  end

  # A name that carries a hygiene mark from a macro template but was
  # never bound by an introduced binder is a free reference to the
  # unmarked base name — usually a runtime primitive like `+`. The base
  # is looked up from the top of the scope, and does not itself get a
  # second marked fallback.
  defp marked_fallback(name, full, pos) do
    case SyntaxRules.strip_mark(name) do
      {:ok, base} -> resolve(base, full, 0, full, false, pos)
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

  defp analyze_if([test | [then_e | []]], t, scope) do
    {:if, analyze(test, nth(t, 1), scope), analyze(then_e, nth(t, 2), scope),
     {:const, :unspecified}}
  end

  defp analyze_if([test | [then_e | [else_e | []]]], t, scope) do
    {:if, analyze(test, nth(t, 1), scope), analyze(then_e, nth(t, 2), scope),
     analyze(else_e, nth(t, 3), scope)}
  end

  defp analyze_if(_, _t, _scope), do: raise(Error, reason: {:bad_special_form, "if"})

  defp analyze_lambda([_params_form | []], _t, _scope) do
    raise(Error, reason: {:bad_special_form, "lambda"})
  end

  defp analyze_lambda([params_form | body], t, scope),
    do: lambda(params_form, body, Pos.drop(t, 2), nil, scope)

  defp analyze_lambda(_, _t, _scope), do: raise(Error, reason: {:bad_special_form, "lambda"})

  # The closure body carries the frame's names tuple alongside the
  # analysed forms so application can build the positional frame
  # without converting the parameter list each call. `bt` is the
  # body's spine tree.
  defp lambda(params_form, body, bt, name, scope) do
    params = parse_params(params_form)
    {frame, names} = pos_frame(spec_names(params))
    {:lambda, params, {names, analyze_body(body, bt, [frame | scope])}, name}
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

  defp analyze_define([{:sym, name} | [expr | []]], t, scope) do
    {:define, name, analyze(expr, nth(t, 2), scope)}
  end

  defp analyze_define([[{:sym, _name} | _params] | []], _t, _scope) do
    raise(Error, reason: {:bad_special_form, "define"})
  end

  defp analyze_define([[{:sym, name} | params_form] | body], t, scope) do
    {:define, name, lambda(params_form, body, Pos.drop(t, 2), name, scope)}
  end

  defp analyze_define(_, _t, _scope), do: raise(Error, reason: {:bad_special_form, "define"})

  defp analyze_define_values([formals | [expr | []]], t, scope) do
    {:define_values, parse_define_values_formals(formals), analyze(expr, nth(t, 2), scope)}
  end

  defp analyze_define_values(_, _t, _scope),
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

  defp analyze_letrec_star([bindings_form | body], t, scope) when body != [] do
    parsed = parse_bindings(bindings_form, nth(t, 1), [])
    names = parsed |> Enum.flat_map(&binding_names/1) |> Enum.uniq()
    slots = names |> Enum.with_index() |> Map.new()
    rec_scope = [{:rec, slots} | scope]

    bindings =
      Enum.map(parsed, fn
        {:single, name, init, it} ->
          {:single, Map.fetch!(slots, name), analyze(init, it, rec_scope)}

        {:multi, spec, init, it} ->
          targets = Enum.map(spec_names(spec), &Map.fetch!(slots, &1))
          {:multi, spec, analyze(init, it, rec_scope), targets}
      end)

    body = analyze_deferred_body(body, Pos.drop(t, 2), rec_scope)
    sequential_values({:letrec, names, bindings, body})
  end

  defp analyze_letrec_star(_, _t, _scope),
    do: raise(Error, reason: {:bad_special_form, "letrec*"})

  # `letrec*` bindings are normally `(name init)`. The body desugarer
  # emits a second internal-only shape, `{:multi_vals, params_spec}`
  # in the head slot, to splice `define-values` into the rec frame
  # without mutation: one init expression produces a value list whose
  # elements are bound across multiple rec slots in a single step.
  # The Elixir-tagged head is unreachable from Scheme source, so the
  # surface `letrec*` syntax is unchanged.
  defp parse_bindings([], _t, acc), do: Enum.reverse(acc)

  defp parse_bindings([[{:sym, name} | [init | []]] | rest], t, acc) do
    parse_bindings(rest, cdr(t), [{:single, name, init, nth(car(t), 1)} | acc])
  end

  defp parse_bindings([[{:multi_vals, spec} | [init | []]] | rest], t, acc) do
    parse_bindings(rest, cdr(t), [{:multi, spec, init, nth(car(t), 1)} | acc])
  end

  defp parse_bindings(_, _t, _), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  defp binding_names({:single, name, _, _}), do: [name]
  defp binding_names({:multi, spec, _, _}), do: spec_names(spec)

  # Rewrite the candidate frame's references to positional slots when
  # every init, including its nested procedure bodies, only references
  # earlier bindings. Init closures capture that partially filled
  # immutable frame; body closures capture the fully initialized one.
  # Duplicate targets keep their existing recursive-frame semantics.
  defp sequential_values({:letrec, names, bindings, body} = node) do
    {bindings, ready} = Enum.map_reduce(bindings, MapSet.new(), &sequential_binding/2)
    body = sequential_refs(body, 0, ready)
    {:letseq, List.to_tuple(names), bindings, body}
  catch
    :needs_recursive_frame -> known_calls(node)
  end

  defp sequential_binding({:single, slot, init}, ready) do
    init = sequential_refs(init, 0, ready)
    {{:single, slot, init}, ready_slot(slot, ready)}
  end

  defp sequential_binding({:multi, spec, init, slots}, ready) do
    init = sequential_refs(init, 0, ready)
    {{:multi, spec, init, slots}, Enum.reduce(slots, ready, &ready_slot/2)}
  end

  defp ready_slot(slot, ready) do
    if MapSet.member?(ready, slot), do: throw(:needs_recursive_frame)
    MapSet.put(ready, slot)
  end

  # Track the candidate frame through nested scopes. A reference's
  # fallback is resolved against that same scope, so it keeps `d`.
  defp sequential_refs({:rref, d, slot, _, _, _}, d, ready) do
    if not MapSet.member?(ready, slot), do: throw(:needs_recursive_frame)
    {:lref, d, slot + 1}
  end

  defp sequential_refs({tag, _} = leaf, _d, _ready) when tag in [:const, :raise, :qc],
    do: leaf

  defp sequential_refs({:lambda, params, {names, body}, name}, d, ready),
    do: {:lambda, params, {names, sequential_refs(body, d + 1, ready)}, name}

  defp sequential_refs({:fixrec, lambdas, body}, d, ready) do
    lambdas = for {names, fbody} <- lambdas, do: {names, sequential_refs(fbody, d + 2, ready)}
    {:fixrec, lambdas, sequential_refs(body, d + 1, ready)}
  end

  defp sequential_refs({tag, names, bindings, body}, d, ready) when tag in [:letrec, :letseq],
    do: {tag, names, sequential_refs(bindings, d + 1, ready), sequential_refs(body, d + 1, ready)}

  defp sequential_refs({:guard, names, clauses, body}, d, ready),
    do: {:guard, names, sequential_refs(clauses, d + 1, ready), sequential_refs(body, d, ready)}

  defp sequential_refs(tuple, d, ready) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> sequential_refs(d, ready) |> List.to_tuple()

  defp sequential_refs(list, d, ready) when is_list(list),
    do: Enum.map(list, &sequential_refs(&1, d, ready))

  defp sequential_refs(other, _d, _ready), do: other

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

  defp known({:app, {:rref, d, slot, _name, _fallback, _pos}, args, _app_pos}, d, false, info) do
    {n, fnames} = elem(info, slot)
    if length(args) != n, do: throw(:not_known)
    {:known_call, d, slot, fnames, known_all(args, d, false, info)}
  end

  defp known({:rref, d, _slot, _name, _fallback, _pos}, d, _lam?, _info), do: throw(:not_known)

  defp known({:rref, depth, slot, name, fallback, pos}, d, lam?, info),
    do: {:rref, depth, slot, name, known(fallback, d, lam?, info), pos}

  defp known({:gref, _name, nil, _pos} = ref, _d, _lam?, _info), do: ref

  defp known({:gref, name, marked, pos}, d, lam?, info),
    do: {:gref, name, known(marked, d, lam?, info), pos}

  defp known({tag, _} = leaf, _d, _lam?, _info) when tag in [:const, :raise], do: leaf
  defp known({:lref, _, _} = ref, _d, _lam?, _info), do: ref

  defp known({:if, test, then_e, else_e}, d, lam?, info),
    do:
      {:if, known(test, d, lam?, info), known(then_e, d, lam?, info),
       known(else_e, d, lam?, info)}

  defp known({:app, head, args, pos}, d, lam?, info),
    do: {:app, known(head, d, lam?, info), known_all(args, d, lam?, info), pos}

  defp known({:known_call, depth, slot, fnames, args}, d, lam?, info),
    do: {:known_call, depth, slot, fnames, known_all(args, d, lam?, info)}

  defp known({:lambda, params, {fnames, body}, name}, d, _lam?, info),
    do: {:lambda, params, {fnames, known_all(body, d + 1, true, info)}, name}

  defp known({:define, name, expr}, d, lam?, info),
    do: {:define, name, known(expr, d, lam?, info)}

  defp known({:define_values, spec, expr}, d, lam?, info),
    do: {:define_values, spec, known(expr, d, lam?, info)}

  defp known({:seq, body}, d, lam?, info), do: {:seq, known_all(body, d, lam?, info)}

  defp known({tag, names, bindings, body}, d, lam?, info) when tag in [:letrec, :letseq] do
    bindings =
      Enum.map(bindings, fn
        {:single, slot, init} -> {:single, slot, known(init, d + 1, lam?, info)}
        {:multi, spec, init, slots} -> {:multi, spec, known(init, d + 1, lam?, info), slots}
      end)

    {tag, names, bindings, known_all(body, d + 1, lam?, info)}
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

  defp known_clause({:arrow, test, proc, pos}, d, lam?, info),
    do: {:arrow, known(test, d, lam?, info), known(proc, d, lam?, info), pos}

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

  defp analyze_quasiquote([datum | []], t, scope),
    do: {:quasi, template(datum, nth(t, 1), 1, scope)}

  defp analyze_quasiquote(_, _t, _scope),
    do: raise(Error, reason: {:bad_special_form, "quasiquote"})

  defp template([{:sym, "unquote"} | [expr | []]], t, 1, scope),
    do: {:qu, analyze(expr, nth(t, 1), scope)}

  defp template([{:sym, "unquote"} | [expr | []]], t, n, scope) when n > 1 do
    qlist([{:qc, Value.symbol("unquote")}, template(expr, nth(t, 1), n - 1, scope)])
  end

  defp template([{:sym, "quasiquote"} | [expr | []]], t, n, scope) do
    qlist([{:qc, Value.symbol("quasiquote")}, template(expr, nth(t, 1), n + 1, scope)])
  end

  defp template([head | tail], t, level, scope) do
    case head do
      [{:sym, "unquote-splicing"} | [expr | []]] when level == 1 ->
        {:qsplice, analyze(expr, nth(car(t), 1), scope), template(tail, cdr(t), level, scope)}

      _ ->
        qcons(template(head, car(t), level, scope), template(tail, cdr(t), level, scope))
    end
  end

  defp template({:vector, items}, t, level, scope) do
    tree =
      case t do
        {:vector, p, trees} -> Pos.list(trees, nil, {:atom, p})
        _ -> nil
      end

    case template(Value.list(Tuple.to_list(items)), tree, level, scope) do
      {:qc, list} -> {:qc, Value.vector(list)}
      other -> {:qvec, other}
    end
  end

  defp template(other, _t, _level, _scope), do: {:qc, other}

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

  defp analyze_guard([[{:sym, var} | clauses_form] | body], t, scope)
       when is_binary(var) and body != [] do
    {frame, names} = pos_frame([var])
    clauses = guard_clauses(clauses_form, cdr(nth(t, 1)), t, [frame | scope])
    {:guard, names, clauses, analyze_deferred_body(body, Pos.drop(t, 2), scope)}
  end

  defp analyze_guard(_, _t, _scope), do: raise(Error, reason: {:bad_special_form, "guard"})

  # `ct` is the clause list's spine tree and `gt` the `guard` form's
  # tree, where a malformed clause list is reported.
  defp guard_clauses([], _ct, _gt, _scope), do: []

  defp guard_clauses([[{:sym, "else"} | body] | _rest], ct, _gt, scope) when body != [] do
    [{:else, analyze_deferred_body(body, cdr(car(ct)), scope)}]
  end

  defp guard_clauses([clause | rest], ct, gt, scope),
    do: [guard_clause(clause, car(ct), scope) | guard_clauses(rest, cdr(ct), gt, scope)]

  defp guard_clauses(_, _ct, gt, _scope), do: [bad_guard(gt)]

  defp guard_clause([test | []], t, scope), do: {:test, analyze(test, car(t), scope)}

  defp guard_clause([test | [{:sym, "=>"} | [proc_expr | []]]], t, scope) do
    {:arrow, analyze(test, car(t), scope), analyze(proc_expr, nth(t, 2), scope), at(t)}
  end

  defp guard_clause([test | body], t, scope) when body != [] do
    {:test_body, analyze(test, car(t), scope), analyze_deferred_body(body, cdr(t), scope)}
  end

  defp guard_clause(_, t, _scope), do: bad_guard(t)

  defp bad_guard(t),
    do: {:bad, locate(Error.exception(reason: {:bad_special_form, "guard"}), t)}

  # ---------------------------------------------------------------------------
  # Bodies
  # ---------------------------------------------------------------------------

  # Desugaring errors in this body fail the enclosing node (lambda,
  # define-fn), so they surface when the closure is created. `bt` is the
  # body's spine tree.
  defp analyze_body(body, bt, scope) do
    body
    |> with_trees(bt)
    |> desugar_body()
    |> Enum.map(fn {form, t} -> analyze(form, t, scope) end)
  end

  # A body whose desugaring errors surface only once the body runs.
  defp analyze_deferred_body(body, bt, scope) do
    analyze_body(body, bt, scope)
  rescue
    e in Error -> [{:raise, locate(e, bt)}]
  end

  defp raise_at(reason, t), do: raise(locate(Error.exception(reason: reason), t))

  # r7rs §5.3.2 lets a body begin with a sequence of `define` forms
  # followed by a sequence of expressions; the defines splice into a
  # `letrec*` whose body is the rest of the forms. `desugar_body/1`
  # performs that rewrite on `{form, tree}` pairs, placing the `letrec*`
  # at the first definition. Forms with no leading defines are returned
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

      {[first | _] = defs, rest} ->
        dt = elem(first, tuple_size(first) - 1)
        {bindings, binding_trees} = defs |> Enum.map(&letrec_binding/1) |> Enum.unzip()
        {forms, trees} = Enum.unzip(rest)
        letrec_form = [{:sym, "letrec*"} | [bindings | forms]]
        letrec_tree = Pos.list([car(dt), Pos.list(binding_trees, nil, dt) | trees], nil, dt)
        [{letrec_form, letrec_tree}]
    end
  end

  defp scan_defines([], acc), do: {Enum.reverse(acc), []}

  # r7rs §5.3.2: a `(begin <form> ...)` at the head of a body is
  # spliced into the body in place. This is what lets
  # `define-record-type` work in an internal-definition position —
  # the expander emits a `(begin (define ...) (define ...) ...)`
  # for each record type and the splicing here makes those defines
  # behave as if they were written at the body level directly.
  defp scan_defines([{[{:sym, "begin"} | inner], t} | rest], acc) do
    scan_defines(splice_begin(inner, cdr(t), rest, t), acc)
  end

  defp scan_defines([{form, t} | rest] = body, acc) do
    case parse_internal_define(form, t) do
      nil ->
        check_no_more_defines(rest)
        {Enum.reverse(acc), body}

      binding ->
        scan_defines(rest, [binding | acc])
    end
  end

  defp parse_internal_define([{:sym, "define"} | body], t) do
    case body do
      [{:sym, name} | [expr | []]] ->
        {:single, name, expr, nth(t, 2), t}

      [[{:sym, name} | params] | body_forms] when body_forms != [] ->
        lambda_tree = Pos.cons(car(t), Pos.cons(cdr(nth(t, 1)), Pos.drop(t, 2), t), t)
        {:single, name, [{:sym, "lambda"} | [params | body_forms]], lambda_tree, t}

      _ ->
        raise_at({:bad_special_form, "define"}, t)
    end
  end

  # r7rs §5.3.3: `define-values` in internal-definition position fans
  # out into a single multi-binding letrec* frame. The producer is
  # evaluated once, and its values are spread across the formals'
  # lexical slots in lock-step — no mutation, no auxiliary tmp visible to
  # the user.
  defp parse_internal_define([{:sym, "define-values"} | body], t) do
    case body do
      [formals | [expr | []]] ->
        {:multi, parse_define_values_formals(formals), expr, nth(t, 2), t}

      _ ->
        raise_at({:bad_special_form, "define-values"}, t)
    end
  rescue
    e in Error -> reraise locate(e, t), __STACKTRACE__
  end

  defp parse_internal_define(_, _t), do: nil

  defp check_no_more_defines([]), do: :ok

  defp check_no_more_defines([{[{:sym, "begin"} | inner], t} | rest]) do
    check_no_more_defines(splice_begin(inner, cdr(t), rest, t))
  end

  defp check_no_more_defines([{form, t} | rest]) do
    if parse_internal_define(form, t) != nil do
      raise_at(:define_after_expression, t)
    else
      check_no_more_defines(rest)
    end
  end

  defp splice_begin([], _it, rest, _t), do: rest

  defp splice_begin([h | more], it, rest, t),
    do: [{h, car(it)} | splice_begin(more, cdr(it), rest, t)]

  defp splice_begin(_, _it, _rest, t), do: raise_at({:bad_special_form, "begin"}, t)

  # Each definition becomes a `letrec*` binding. A `define-values`
  # emits the internal `{:multi_vals, spec}` binding head described at
  # `parse_bindings/3`.
  defp letrec_binding({:single, name, init, it, dt}),
    do: {[{:sym, name} | [init | []]], Pos.list([nth(dt, 1), it], nil, dt)}

  defp letrec_binding({:multi, spec, init, it, dt}),
    do: {[{:multi_vals, spec} | [init | []]], Pos.list([nth(dt, 1), it], nil, dt)}
end
