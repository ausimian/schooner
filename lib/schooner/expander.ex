defmodule Schooner.Expander do
  @moduledoc """
  Datum-AST → core-AST expansion pass.

  Walks the reader's output, applies `define-syntax` / `let-syntax` /
  `letrec-syntax` bindings to expand macro uses, and leaves only the
  core forms for the evaluator: `quote`, `if`, `lambda`, `define`,
  `define-values`, `begin`, `letrec*`, `quasiquote`, `guard`,
  application, and variable reference. `define-record-type` expands
  to a `begin` of `define`s. The derived forms (`let`, `cond`, `case`,
  `do`, and so on) are `syntax-rules` macros in the bootstrap syntax
  env.

  Hygiene is by alpha-renaming with a fresh per-expansion mark; see
  `Schooner.Expander.SyntaxRules`. This module drives expansion to a
  fixed point and pushes `:variable` frames for local bindings, so a
  local variable named after a macro keyword (a parameter called
  `when`, say) shadows the macro.

  ## Positions

  The positioned entry points take each form with its
  `Schooner.Reader` position tree and return the expanded form with a
  tree that mirrors it, so analysis can place every core form in the
  source. Core forms keep the trees of their parts. A macro's output
  takes the position of the macro use, except for the sub-forms the
  user wrote, which keep their own (see "Positions" in
  `Schooner.Expander.SyntaxRules`). An expansion error is
  given the location of the innermost positioned form being expanded,
  without a file; the caller that knows the file adds it.

  ## Top-level vs. internal `define-syntax`

  Only top-level `define-syntax` is supported, including within
  nested top-level `begin` forms. These macros remain visible to
  later top-level forms. A `define-syntax` anywhere else raises
  `Schooner.Eval.Error` with reason
  `:nested_define_syntax_unsupported`; `let-syntax` and
  `letrec-syntax` cover local macro definitions.
  """

  alias Schooner.Eval.Error
  alias Schooner.Expander.Derived
  alias Schooner.Expander.Error, as: ExpanderError
  alias Schooner.Expander.Positions, as: Pos
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Expander.SyntaxRules
  alias Schooner.Location
  alias Schooner.Primitives.Record, as: RecordPrim
  alias Schooner.Reader
  alias Schooner.Value

  # Core special forms. A hygiene-marked symbol whose base name is in
  # this set is re-dispatched on the canonical name (`resolve_base/2`).
  #
  # `letrec*` stays a core form because it backs both user-facing
  # recursive bindings and internal-define splicing in
  # `Schooner.Eval.Analyze`; a macro replacement would need either
  # mutation or a hand-built fix-point combinator. For why
  # `define-record-type` is core, see `expand_define_record_type/3`.
  @core_specials MapSet.new(
                   ~w(quote if lambda define define-values begin set! letrec* define-record-type guard)
                 )

  # Local, inlined copies of `Positions.car/1` and `Positions.cdr/1`,
  # and a `Positions.cons/3` that skips the call when there is no tree:
  # these run for every element of every form expanded.
  @compile {:inline, car: 1, cdr: 1, cons: 3}
  defp car({:pair, _, car, _}), do: car
  defp car(_), do: nil
  defp cdr({:pair, _, _, cdr}), do: cdr
  defp cdr(_), do: nil
  defp cons(_car, _cdr, nil), do: nil
  defp cons(car, cdr, tree), do: Pos.cons(car, cdr, tree)

  @typedoc "A form paired with its position tree (`nil` when unknown)."
  @type positioned :: {Value.t(), Pos.t()}

  @doc """
  Expand a list of top-level forms in `env`. Returns a list of
  expanded forms with all `define-syntax` / `let-syntax` /
  `letrec-syntax` and macro uses resolved to core forms.
  """
  @spec expand_program([Value.t()], SyntaxEnv.t()) :: [Value.t()]
  def expand_program(forms, %SyntaxEnv{} = env) when is_list(forms) do
    {expanded, _env} = expand_program_with_env(forms, env)
    expanded
  end

  @doc """
  Expand a list of top-level forms in `env` and return both the
  expanded forms and the resulting syntax env. Unlike `expand_program/2`,
  this preserves the env so callers can extract macros introduced by
  top-level `define-syntax` forms — which is how
  `Schooner.Library.Standard` lifts each `priv/scheme/*.scm` file's
  macros into a library's exports.
  """
  @spec expand_program_with_env([Value.t()], SyntaxEnv.t()) ::
          {[Value.t()], SyntaxEnv.t()}
  def expand_program_with_env(forms, %SyntaxEnv{} = env) when is_list(forms) do
    {expanded, env} = expand_positioned(Enum.map(forms, &{&1, nil}), env)
    {Enum.map(expanded, &elem(&1, 0)), env}
  end

  @doc """
  Expand a list of `{form, position_tree}` top-level forms, as read by
  `Schooner.Reader.read_string_positioned/1`, in `env`. Returns the
  expanded `{form, position_tree}` pairs and the resulting syntax env.
  """
  @spec expand_positioned([positioned()], SyntaxEnv.t()) :: {[positioned()], SyntaxEnv.t()}
  def expand_positioned(forms, %SyntaxEnv{} = env) when is_list(forms) do
    expand_top_seq(forms, env, [])
  end

  @doc """
  Return the cached bootstrap syntax env containing the derived-form
  macros.

  `Schooner.Application.start/2` builds and caches it at startup, so
  the first `Schooner.eval/2` call on a node does not pay the
  parse-and-expand cost. If the application has not been started (in
  some tests, for example), the first call builds and caches it here
  instead.

  That fallback is *not* race-safe: two callers that both see `:unset`
  will both build and `put`, and the second `put` replaces an existing
  `:persistent_term` key, which triggers a global literal-area GC
  across all processes. Building once at application start avoids
  this.
  """
  @spec bootstrap_env() :: SyntaxEnv.t()
  def bootstrap_env do
    case :persistent_term.get({__MODULE__, :bootstrap_env}, :unset) do
      :unset ->
        env = build_bootstrap_env()
        :persistent_term.put({__MODULE__, :bootstrap_env}, env)
        env

      env ->
        env
    end
  end

  defp build_bootstrap_env do
    forms = Reader.read_string(Derived.source())
    {_, env} = expand_program_with_env(forms, SyntaxEnv.new())
    env
  end

  # ---------------------------------------------------------------------------
  # Top-level sequence
  # ---------------------------------------------------------------------------

  defp expand_top_seq([], env, acc), do: {Enum.reverse(acc), env}

  defp expand_top_seq([{form, t} | rest], env, acc) do
    case expand_top(form, t, env) do
      {:syntax_def, env2} -> expand_top_seq(rest, env2, acc)
      {:expanded, expanded, env2} -> expand_top_seq(rest, env2, [expanded | acc])
    end
  end

  defp expand_top(form, nil, env), do: expand_top_form(form, nil, env)

  defp expand_top(form, t, env) do
    expand_top_form(form, t, env)
  rescue
    e in [Error, ExpanderError] -> reraise locate(e, t), __STACKTRACE__
  end

  defp expand_top_form([{:sym, "define-syntax"} | tail], _t, env) do
    {name, transformer} = parse_define_syntax(tail, env)
    {:syntax_def, SyntaxEnv.define_macro(env, name, transformer)}
  end

  defp expand_top_form([{:sym, "begin"} | body], t, env) do
    expand_top_begin(body, cdr(t), t, env, [])
  end

  defp expand_top_form(form, t, env), do: {:expanded, ex(form, t, env), env}

  defp expand_top_begin([], _bt, t, env, acc) do
    case acc do
      [] ->
        {:syntax_def, env}

      _ ->
        {forms, trees} = acc |> Enum.reverse() |> Enum.unzip()
        form = [{:sym, "begin"} | Value.list(forms)]
        {:expanded, {form, Pos.list([car(t) | trees], nil, t)}, env}
    end
  end

  defp expand_top_begin([form | rest], bt, t, env, acc) do
    case expand_top(form, car(bt), env) do
      {:syntax_def, env2} ->
        expand_top_begin(rest, cdr(bt), t, env2, acc)

      {:expanded, expanded, env2} ->
        expand_top_begin(rest, cdr(bt), t, env2, [expanded | acc])
    end
  end

  defp expand_top_begin(_, _bt, _t, _env, _acc),
    do: raise(Error, reason: {:bad_special_form, "begin"})

  # ---------------------------------------------------------------------------
  # Recursive expansion of an arbitrary form
  # ---------------------------------------------------------------------------

  @doc "Expand a single form to a fixed point."
  @spec expand(Value.t(), SyntaxEnv.t()) :: Value.t()
  def expand(form, env), do: form |> ex(nil, env) |> elem(0)

  # Expand `form`, whose position tree is `t`, returning the expanded
  # form and its tree. A failure inside a positioned list form is
  # placed at that form unless something nested already placed it.
  defp ex([_ | _] = form, t, env) when t != nil do
    ex_form(form, t, env)
  rescue
    e in [Error, ExpanderError] -> reraise locate(e, t), __STACKTRACE__
  end

  defp ex(form, t, env), do: ex_form(form, t, env)

  defp locate(e, t), do: Location.attach(e, Location.new(nil, Pos.at(t)))

  defp ex_form([{:sym, "quote"} | _] = form, t, _env), do: {form, t}

  defp ex_form([{:sym, "lambda"} | tail], t, env), do: expand_lambda(tail, t, env)

  defp ex_form([{:sym, "define"} | tail], t, env), do: expand_define(tail, t, env)

  defp ex_form([{:sym, "define-values"} | tail], t, env), do: expand_define_values(tail, t, env)

  defp ex_form([{:sym, "if"} | tail], t, env), do: expand_if(tail, t, env)

  defp ex_form([{:sym, "begin"} | tail], t, env) do
    {body, bt} = ex_each(tail, cdr(t), env)
    {[{:sym, "begin"} | body], cons(car(t), bt, t)}
  end

  defp ex_form([{:sym, "letrec*"} | tail], t, env), do: expand_letrec_star(tail, t, env)

  defp ex_form([{:sym, "set!"} | _tail], _t, _env) do
    raise Error, reason: {:bad_special_form, "set!"}
  end

  defp ex_form([{:sym, "let-syntax"} | tail], t, env), do: expand_let_syntax(tail, t, env)

  defp ex_form([{:sym, "letrec-syntax"} | tail], t, env), do: expand_letrec_syntax(tail, t, env)

  defp ex_form([{:sym, "define-syntax"} | _tail], _t, _env) do
    raise Error, reason: :nested_define_syntax_unsupported
  end

  defp ex_form([{:sym, "quasiquote"} | _tail] = form, t, env) do
    expand_quasiquote(form, t, env)
  end

  defp ex_form([{:sym, "define-record-type"} | tail], t, env) do
    expand_define_record_type(tail, t, env)
  end

  defp ex_form([{:sym, "guard"} | tail], t, env), do: expand_guard(tail, t, env)

  defp ex_form([{:sym, name} | _args] = form, t, env) do
    case lookup_with_fallback(env, name) do
      {:macro, transformer} ->
        {new_form, new_t} = transformer.(form, t)
        ex(new_form, new_t, env)

      {:special, base} ->
        # A core special form's name appeared with a hygiene mark.
        # Re-dispatch on the canonical name so the special-form
        # clauses above pick it up and emit canonical output.
        canonicalise_special(base, form, t, env)

      _ ->
        expand_application(form, t, env)
    end
  end

  defp ex_form([_head | _tail] = form, t, env), do: expand_application(form, t, env)

  defp ex_form(other, t, _env), do: {other, t}

  # ---------------------------------------------------------------------------
  # Special-form expanders
  # ---------------------------------------------------------------------------

  defp expand_application([head | args], t, env) do
    {head, ht} = ex(head, car(t), env)
    {args, at} = ex_each(args, cdr(t), env)
    {[head | args], cons(ht, at, t)}
  end

  # A core special form's name reached us with a hygiene mark: a
  # template used a core form (`letrec*`, `guard`, ...) that is not in
  # `SyntaxRules`'s `@core_keywords`, so instantiation marked it.
  # Re-dispatch on the canonical name so the dedicated handlers fire.
  defp canonicalise_special(base, [{:sym, _} | tail], t, env) do
    ex([{:sym, base} | tail], t, env)
  end

  # Walk the syntax env for `name`. If unbound, strip a hygiene mark
  # and try again. If the stripped name is a known core special form,
  # report that so the caller can re-dispatch on its canonical name.
  defp lookup_with_fallback(env, name) do
    case SyntaxEnv.lookup(env, name) do
      :undefined -> resolve_marked(env, name)
      binding -> binding
    end
  end

  defp resolve_marked(env, name) do
    case SyntaxRules.strip_mark(name) do
      :error -> :undefined
      {:ok, base} -> resolve_base(env, base)
    end
  end

  defp resolve_base(env, base) do
    if MapSet.member?(@core_specials, base) do
      {:special, base}
    else
      case SyntaxEnv.lookup(env, base) do
        {:macro, _} = m -> m
        _ -> :undefined
      end
    end
  end

  # Expand each element of a (possibly improper) list of forms whose
  # spine tree is `t`, returning the expanded list and its spine tree.
  defp ex_each([], t, _env), do: {[], t}

  defp ex_each([h | rest], t, env) do
    {h, ht} = ex(h, car(t), env)
    {rest, rt} = ex_each(rest, cdr(t), env)
    {[h | rest], cons(ht, rt, t)}
  end

  defp ex_each(other, t, _env), do: {other, t}

  defp expand_lambda([params_form | body], t, env) when body != [] do
    inner = SyntaxEnv.push_variables(env, collect_param_names(params_form))
    {body, bt} = ex_each(body, Pos.drop(t, 2), inner)
    {[{:sym, "lambda"} | [params_form | body]], rebuild(t, 2, bt)}
  end

  defp expand_lambda(_, _t, _env), do: raise(Error, reason: {:bad_special_form, "lambda"})

  # The tree of a form whose first `n` elements are kept as written and
  # whose remaining elements were expanded to the spine tree `rest_t`.
  defp rebuild(nil, _n, _rest_t), do: nil
  defp rebuild(_t, 0, rest_t), do: rest_t
  defp rebuild(t, n, rest_t), do: cons(car(t), rebuild(cdr(t), n - 1, rest_t), t)

  defp collect_param_names({:sym, name}), do: [name]
  defp collect_param_names([]), do: []

  defp collect_param_names([{:sym, name} | rest]) do
    [name | collect_param_names(rest)]
  end

  defp collect_param_names(_), do: raise(Error, reason: {:bad_special_form, "lambda"})

  defp expand_define([{:sym, name} | [expr | []]], t, env) do
    {expr, et} = ex(expr, Pos.nth(t, 2), env)

    {[{:sym, "define"} | [{:sym, name} | [expr | []]]],
     rebuild(t, 2, cons(et, Pos.drop(t, 3), t))}
  end

  defp expand_define([[{:sym, name} | params] | body], t, env) when body != [] do
    inner = SyntaxEnv.push_variables(env, collect_param_names(params))
    {body, bt} = ex_each(body, Pos.drop(t, 2), inner)

    {[{:sym, "define"} | [[{:sym, name} | params] | body]], rebuild(t, 2, bt)}
  end

  defp expand_define(_, _t, _env), do: raise(Error, reason: {:bad_special_form, "define"})

  # `define-values` is a core form rather than a `syntax-rules` macro
  # because, in internal-definition position, it has to fan out into
  # multiple recursive bindings from a single evaluation of the
  # producer; the body desugarer in `Schooner.Eval.Analyze` does that
  # splice. The expander only validates the formals and expands the
  # producer expression.
  defp expand_define_values([formals | [producer | []]], t, env) do
    validate_define_values_formals(formals)
    {producer, pt} = ex(producer, Pos.nth(t, 2), env)

    {[{:sym, "define-values"} | [formals | [producer | []]]],
     rebuild(t, 2, cons(pt, Pos.drop(t, 3), t))}
  end

  defp expand_define_values(_, _t, _env),
    do: raise(Error, reason: {:bad_special_form, "define-values"})

  defp validate_define_values_formals({:sym, _}), do: :ok
  defp validate_define_values_formals([]), do: :ok

  defp validate_define_values_formals([{:sym, _} | rest]),
    do: validate_define_values_formals(rest)

  defp validate_define_values_formals(_),
    do: raise(Error, reason: {:bad_special_form, "define-values"})

  defp expand_if([_test | [_then_e | rest]] = tail, t, env) when rest == [] or tl(rest) == [] do
    {tail, tt} = ex_each(tail, cdr(t), env)
    {[{:sym, "if"} | tail], cons(car(t), tt, t)}
  end

  defp expand_if(_, _t, _env), do: raise(Error, reason: {:bad_special_form, "if"})

  defp expand_letrec_star([bindings_form | body], t, env) when body != [] do
    parsed = parse_letrec_bindings(bindings_form, Pos.nth(t, 1), [])
    names = Enum.map(parsed, fn {sym, _, _} -> sym_name(sym) end)
    inner = SyntaxEnv.push_variables(env, names)

    {bindings, binding_trees} =
      parsed
      |> Enum.map(fn {sym, init, bt} ->
        {init, it} = ex(init, Pos.nth(bt, 1), inner)
        {[sym | [init | []]], Pos.list([car(bt), it], nil, bt)}
      end)
      |> Enum.unzip()

    {body, body_t} = ex_each(body, Pos.drop(t, 2), inner)
    bindings_t = Pos.list(binding_trees, nil, Pos.nth(t, 1))

    {[{:sym, "letrec*"} | [Value.list(bindings) | body]],
     rebuild(t, 1, cons(bindings_t, body_t, t))}
  end

  defp expand_letrec_star(_, _t, _env), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  defp sym_name({:sym, name}), do: name

  # Parse the binding list once into `[{sym, init, binding_tree}, ...]`.
  # The caller uses the result twice: to derive the binder names for the
  # syntax-env shadow, and to expand the inits in that shadowed env.
  defp parse_letrec_bindings([], _t, acc), do: Enum.reverse(acc)

  defp parse_letrec_bindings([[{:sym, _} = sym | [init | []]] | rest], t, acc) do
    parse_letrec_bindings(rest, cdr(t), [{sym, init, car(t)} | acc])
  end

  defp parse_letrec_bindings(_, _t, _),
    do: raise(Error, reason: {:bad_special_form, "letrec*"})

  # ---------------------------------------------------------------------------
  # define-record-type
  # ---------------------------------------------------------------------------

  # `define-record-type` is a core form rather than a macro because
  # it has to mint a fresh type identity at expansion time and embed
  # it as a literal in the bindings it generates — `syntax-rules`
  # templates are pure substitution and can't introduce a fresh
  # constant per use. Every generated definition takes the position of
  # the `define-record-type` form, so an error inside a constructor,
  # predicate or accessor is placed there: the call into it is a tail
  # call, so nothing is left at the caller to place it.
  defp expand_define_record_type(form, t, env) do
    {name, {ctor_name, ctor_fields}, pred_name, fields} = parse_record_type(form)
    type_id = fresh_record_type_id(name)
    field_names = Enum.map(fields, fn {fname, _accessor} -> fname end)

    defs = [
      record_constructor_def(ctor_name, ctor_fields, field_names, type_id),
      record_predicate_def(pred_name, type_id)
      | record_accessor_defs(fields, type_id)
    ]

    begin = [{:sym, "begin"} | Value.list(defs)]
    ex(begin, Pos.fresh(begin, t), env)
  end

  defp fresh_record_type_id(name) when is_binary(name) do
    {:record_type, name, :erlang.unique_integer([:positive])}
  end

  defp parse_record_type([{:sym, name} | [ctor_spec | [{:sym, pred_name} | field_specs_form]]])
       when is_binary(name) and is_binary(pred_name) do
    {name, parse_record_ctor(ctor_spec), pred_name,
     parse_record_field_specs(field_specs_form, [])}
  end

  defp parse_record_type(_), do: raise(Error, reason: {:bad_special_form, "define-record-type"})

  defp parse_record_ctor([{:sym, ctor_name} | fields_form]) when is_binary(ctor_name) do
    {ctor_name, parse_record_ctor_fields(fields_form, [])}
  end

  defp parse_record_ctor(_), do: raise(Error, reason: {:bad_special_form, "define-record-type"})

  defp parse_record_ctor_fields([], acc), do: Enum.reverse(acc)

  defp parse_record_ctor_fields([{:sym, name} | rest], acc) when is_binary(name) do
    parse_record_ctor_fields(rest, [name | acc])
  end

  defp parse_record_ctor_fields(_, _),
    do: raise(Error, reason: {:bad_special_form, "define-record-type"})

  defp parse_record_field_specs([], acc), do: Enum.reverse(acc)

  defp parse_record_field_specs(
         [[{:sym, fname} | [{:sym, accessor} | []]] | rest],
         acc
       )
       when is_binary(fname) and is_binary(accessor) do
    parse_record_field_specs(rest, [{fname, accessor} | acc])
  end

  defp parse_record_field_specs(_, _),
    do: raise(Error, reason: {:bad_special_form, "define-record-type"})

  defp record_constructor_def(ctor_name, ctor_fields, field_names, type_id) do
    ctor_set = MapSet.new(ctor_fields)
    arg_syms = Enum.map(ctor_fields, &{:sym, &1})

    field_values =
      Enum.map(field_names, fn fname ->
        if MapSet.member?(ctor_set, fname), do: {:sym, fname}, else: :unspecified
      end)

    body = Value.list([{:sym, RecordPrim.instance_name()}, type_id | field_values])
    make_define_form(ctor_name, arg_syms, body)
  end

  defp record_predicate_def(pred_name, type_id) do
    body = Value.list([{:sym, RecordPrim.predicate_name()}, type_id, {:sym, "v"}])
    make_define_form(pred_name, [{:sym, "v"}], body)
  end

  defp record_accessor_defs(fields, type_id) do
    Enum.with_index(fields, fn {_fname, accessor}, idx ->
      body = Value.list([{:sym, RecordPrim.ref_name()}, type_id, {:sym, "v"}, idx])
      make_define_form(accessor, [{:sym, "v"}], body)
    end)
  end

  # Build `(define (<name> <param> ...) <body>)` for the record
  # constructor, predicate, and accessor emitters.
  defp make_define_form(name, params, body) do
    Value.list([{:sym, "define"}, Value.list([{:sym, name} | params]), body])
  end

  # `guard` is a core form rather than a `syntax-rules` macro because
  # it escapes the body with Elixir `throw`/`catch` once a clause
  # matches. (The r7rs reference definition uses `call/cc`, which
  # Schooner did not have when `guard` was added.) The expander
  # expands the body and each clause's test and body, with the
  # condition variable shadowing any same-named macro in the clauses.
  defp expand_guard([[{:sym, var} | clauses_form] | body], t, env)
       when body != [] and is_binary(var) do
    inner = SyntaxEnv.push_variables(env, [var])
    spec_t = Pos.nth(t, 1)
    {clauses, clauses_t} = expand_guard_clauses(clauses_form, cdr(spec_t), inner)
    {body, body_t} = ex_each(body, Pos.drop(t, 2), env)
    spec_t = cons(car(spec_t), clauses_t, spec_t)

    {[{:sym, "guard"} | [[{:sym, var} | clauses] | body]], rebuild(t, 1, cons(spec_t, body_t, t))}
  end

  defp expand_guard(_, _t, _env), do: raise(Error, reason: {:bad_special_form, "guard"})

  defp expand_guard_clauses([], t, _env), do: {[], t}

  defp expand_guard_clauses([clause | rest], t, env) do
    {clause, ct} = expand_guard_clause(clause, car(t), env)
    {rest, rt} = expand_guard_clauses(rest, cdr(t), env)
    {[clause | rest], cons(ct, rt, t)}
  end

  defp expand_guard_clauses(_, _t, _env), do: raise(Error, reason: {:bad_special_form, "guard"})

  # `else` clauses keep their literal head; everything after is a
  # body sequence that gets recursively expanded. `=>` clauses keep
  # the literal arrow and expand the test and the proc expression.
  # Bare `(test)` and `(test e1 e2 ...)` expand the test plus body.
  defp expand_guard_clause([{:sym, "else"} | body], t, env) when body != [] do
    {body, bt} = ex_each(body, cdr(t), env)
    {[{:sym, "else"} | body], cons(car(t), bt, t)}
  end

  defp expand_guard_clause([test | [{:sym, "=>"} | [proc | []]]], t, env) do
    {test, tt} = ex(test, car(t), env)
    {proc, pt} = ex(proc, Pos.nth(t, 2), env)
    {[test | [{:sym, "=>"} | [proc | []]]], Pos.list([tt, Pos.nth(t, 1), pt], nil, t)}
  end

  defp expand_guard_clause([_test | _body] = clause, t, env), do: ex_each(clause, t, env)

  defp expand_guard_clause(_, _t, _env), do: raise(Error, reason: {:bad_special_form, "guard"})

  defp expand_let_syntax([bindings_form | body], t, env) when body != [] do
    bindings = parse_syntax_bindings(bindings_form, env, "let-syntax")
    inner = SyntaxEnv.push_macros(env, bindings)
    expanded = ex_each(body, Pos.drop(t, 2), inner)
    wrap_body_as_form(expanded, t)
  end

  defp expand_let_syntax(_, _t, _env), do: raise(Error, reason: {:bad_special_form, "let-syntax"})

  defp expand_letrec_syntax([bindings_form | body], t, env) when body != [] do
    # Collect names first; compile transformers in an env that already
    # knows about all the new macro names so a transformer can refer to
    # its peers (mutually recursive macros).
    names = collect_macro_binding_names(bindings_form, "letrec-syntax")

    placeholder =
      Enum.map(
        names,
        &{&1, fn _, _ -> raise Error, reason: {:bad_special_form, "letrec-syntax"} end}
      )

    rec_env = SyntaxEnv.push_macros(env, placeholder)
    bindings = parse_syntax_bindings(bindings_form, rec_env, "letrec-syntax")
    inner = SyntaxEnv.push_macros(env, bindings)
    expanded = ex_each(body, Pos.drop(t, 2), inner)
    wrap_body_as_form(expanded, t)
  end

  defp expand_letrec_syntax(_, _t, _env),
    do: raise(Error, reason: {:bad_special_form, "letrec-syntax"})

  # A single body form stands for the whole `let-syntax`; a longer body
  # becomes a `begin` placed at the `let-syntax` form.
  defp wrap_body_as_form({[single | []], bt}, _t), do: {single, car(bt)}

  defp wrap_body_as_form({body, bt}, t),
    do: {[{:sym, "begin"} | body], cons(car(t), bt, t)}

  # ---------------------------------------------------------------------------
  # define-syntax parsing
  # ---------------------------------------------------------------------------

  defp parse_define_syntax([{:sym, name} | [spec | []]], _env) do
    {name, SyntaxRules.compile(spec)}
  end

  defp parse_define_syntax(_, _env),
    do: raise(Error, reason: {:bad_special_form, "define-syntax"})

  defp parse_syntax_bindings([], _env, _ctx), do: []

  defp parse_syntax_bindings([[{:sym, name} | [spec | []]] | rest], env, ctx) do
    [{name, SyntaxRules.compile(spec)} | parse_syntax_bindings(rest, env, ctx)]
  end

  defp parse_syntax_bindings(_, _env, ctx), do: raise(Error, reason: {:bad_special_form, ctx})

  defp collect_macro_binding_names([], _ctx), do: []

  defp collect_macro_binding_names(
         [[{:sym, name} | [_spec | []]] | rest],
         ctx
       ) do
    [name | collect_macro_binding_names(rest, ctx)]
  end

  defp collect_macro_binding_names(_, ctx), do: raise(Error, reason: {:bad_special_form, ctx})

  # ---------------------------------------------------------------------------
  # Quasiquote — recurse into unquoted positions but leave quoted data
  # ---------------------------------------------------------------------------

  defp expand_quasiquote([{:sym, "quasiquote"} | [datum | []]], t, env) do
    {datum, dt} = walk_quasi(datum, Pos.nth(t, 1), env, 1)
    {[{:sym, "quasiquote"} | [datum | []]], Pos.list([car(t), dt], nil, t)}
  end

  defp expand_quasiquote(_, _t, _env),
    do: raise(Error, reason: {:bad_special_form, "quasiquote"})

  defp walk_quasi([{:sym, "unquote"} | [expr | []]], t, env, 1) do
    quasi_pair("unquote", ex(expr, Pos.nth(t, 1), env), t)
  end

  defp walk_quasi([{:sym, "unquote"} | [expr | []]], t, env, n) when n > 1 do
    quasi_pair("unquote", walk_quasi(expr, Pos.nth(t, 1), env, n - 1), t)
  end

  defp walk_quasi([{:sym, "unquote-splicing"} | [expr | []]], t, env, 1) do
    quasi_pair("unquote-splicing", ex(expr, Pos.nth(t, 1), env), t)
  end

  defp walk_quasi([{:sym, "unquote-splicing"} | [expr | []]], t, env, n) when n > 1 do
    quasi_pair("unquote-splicing", walk_quasi(expr, Pos.nth(t, 1), env, n - 1), t)
  end

  defp walk_quasi([{:sym, "quasiquote"} | [expr | []]], t, env, n) do
    quasi_pair("quasiquote", walk_quasi(expr, Pos.nth(t, 1), env, n + 1), t)
  end

  defp walk_quasi([h | rest], t, env, level) do
    {h, ht} = walk_quasi(h, car(t), env, level)
    {rest, rt} = walk_quasi(rest, cdr(t), env, level)
    {[h | rest], cons(ht, rt, t)}
  end

  defp walk_quasi({:vector, items}, t, env, level) do
    trees =
      case t do
        {:vector, _, trees} -> trees
        _ -> List.duplicate(nil, tuple_size(items))
      end

    {new_items, new_trees} =
      items
      |> Tuple.to_list()
      |> Enum.zip(trees)
      |> Enum.map(fn {item, it} -> walk_quasi(item, it, env, level) end)
      |> Enum.unzip()

    {{:vector, List.to_tuple(new_items)}, t && {:vector, Pos.at(t), new_trees}}
  end

  defp walk_quasi(other, t, _env, _level), do: {other, t}

  defp quasi_pair(keyword, {form, ft}, t) do
    {[{:sym, keyword} | [form | []]], Pos.list([car(t), ft], nil, t)}
  end
end
