defmodule Schooner.Expander do
  @moduledoc """
  Datum-AST → core-AST expansion pass.

  Walks the reader's output, applies `define-syntax` / `let-syntax` /
  `letrec-syntax` bindings to expand macro uses, and leaves only the
  core forms — `quote`, `if`, `lambda`, top-level `define`, `begin`,
  application, and variable reference — for the evaluator to consume.
  Everything else, including all of phase 7's derived forms, lives as
  a `syntax-rules` macro registered in the bootstrap syntax env.

  Hygiene is by alpha-renaming with a fresh per-expansion mark; see
  `Schooner.Expander.SyntaxRules` for the details. The expander's job
  in this module is to drive expansion until a fixed point and to
  shadow macro keywords with `:variable` frames so that an inner
  `let` shadowing the bootstrap `let` does the expected thing.

  ## Top-level vs. internal `define-syntax`

  Top-level `define-syntax` is the supported form. Bodies that mix
  internal `define-syntax` with internal `define` are not yet handled
  — `let-syntax` / `letrec-syntax` cover the in-body needs and the
  spec leaves the internal-define-syntax case off the critical path.
  """

  alias Schooner.Eval.Error
  alias Schooner.Expander.Derived
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Expander.SyntaxRules
  alias Schooner.Primitives.Record, as: RecordPrim
  alias Schooner.Reader
  alias Schooner.Value

  # `letrec*` is intentionally retained as a core form: it backs both
  # user-facing recursive bindings and the internal-define splicing
  # done at evaluation time, and a fully-macroised replacement would
  # need either mutation or a hand-built fix-point combinator.
  # `define-record-type` joins the core set because it has to mint a
  # fresh type identity at expansion time and embed it as a literal
  # in the bindings it generates — `syntax-rules` templates are pure
  # substitution and can't introduce a fresh constant per use.
  @core_specials MapSet.new(
                   ~w(quote if lambda define define-values begin set! letrec* define-record-type guard)
                 )

  @doc """
  Expand a list of top-level forms in `env`. Returns a list of
  expanded forms with all `define-syntax` / `let-syntax` /
  `letrec-syntax` and macro uses resolved to core forms.
  """
  @spec expand_program([Value.t()], SyntaxEnv.t()) :: [Value.t()]
  def expand_program(forms, %SyntaxEnv{} = env) when is_list(forms) do
    {expanded, _env} = expand_top_seq(forms, env, [])
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
    expand_top_seq(forms, env, [])
  end

  @doc """
  Return the cached bootstrap syntax env containing the derived-form
  macros.

  Normally populated eagerly by `Schooner.Application.start/2` so that
  the first `Schooner.eval/2` call on the node pays no bootstrap
  parse-and-expand cost and concurrent first-evals cannot race the
  put. A lazy fallback is retained for callers that use the library
  without starting the OTP application (some test scenarios). Under
  normal operation the fallback branch is dead.

  The fallback is *not* race-safe: two callers observing `:unset`
  simultaneously will both build and both `put`; the second `put`
  becomes an update of an existing key, which triggers a global
  literal-area GC across all processes. Eager init from
  `Schooner.Application` avoids this by single-flighting the put.
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
    {_, env} = expand_top_seq(forms, SyntaxEnv.new(), [])
    env
  end

  # ---------------------------------------------------------------------------
  # Top-level sequence
  # ---------------------------------------------------------------------------

  defp expand_top_seq([], env, acc), do: {Enum.reverse(acc), env}

  defp expand_top_seq([form | rest], env, acc) do
    case expand_top(form, env) do
      {:syntax_def, env2} -> expand_top_seq(rest, env2, acc)
      expanded -> expand_top_seq(rest, env, [expanded | acc])
    end
  end

  defp expand_top([{:sym, "define-syntax"} | tail], env) do
    {name, transformer} = parse_define_syntax(tail, env)
    {:syntax_def, SyntaxEnv.define_macro(env, name, transformer)}
  end

  defp expand_top([{:sym, "begin"} | body], env) do
    case expand_top_begin(body, env, []) do
      {:syntax_def, env2} -> {:syntax_def, env2}
      expanded -> expanded
    end
  end

  defp expand_top(form, env), do: expand(form, env)

  defp expand_top_begin([], env, acc) do
    [{:sym, "begin"} | Value.list(Enum.reverse(acc))]
    |> finalise_top_begin(env, acc)
  end

  defp expand_top_begin([form | rest], env, acc) do
    case expand_top(form, env) do
      {:syntax_def, env2} -> expand_top_begin(rest, env2, acc)
      expanded -> expand_top_begin(rest, env, [expanded | acc])
    end
  end

  defp expand_top_begin(_, _env, _acc), do: raise(Error, reason: {:bad_special_form, "begin"})

  defp finalise_top_begin(_form, env, []), do: {:syntax_def, env}

  defp finalise_top_begin(form, _env, _acc), do: form

  # ---------------------------------------------------------------------------
  # Recursive expansion of an arbitrary form
  # ---------------------------------------------------------------------------

  @doc "Expand a single form to a fixed point."
  @spec expand(Value.t(), SyntaxEnv.t()) :: Value.t()
  def expand([{:sym, "quote"} | _] = form, _env), do: form

  def expand([{:sym, "lambda"} | tail], env), do: expand_lambda(tail, env)

  def expand([{:sym, "define"} | tail], env), do: expand_define(tail, env)

  def expand([{:sym, "define-values"} | tail], env), do: expand_define_values(tail, env)

  def expand([{:sym, "if"} | tail], env), do: expand_if(tail, env)

  def expand([{:sym, "begin"} | tail], env) do
    [{:sym, "begin"} | expand_each(tail, env)]
  end

  def expand([{:sym, "letrec*"} | tail], env), do: expand_letrec_star(tail, env)

  def expand([{:sym, "set!"} | _tail], _env) do
    raise Error, reason: {:bad_special_form, "set!"}
  end

  def expand([{:sym, "let-syntax"} | tail], env), do: expand_let_syntax(tail, env)

  def expand([{:sym, "letrec-syntax"} | tail], env), do: expand_letrec_syntax(tail, env)

  def expand([{:sym, "define-syntax"} | _tail], _env) do
    raise Error, reason: :nested_define_syntax_unsupported
  end

  def expand([{:sym, "quasiquote"} | _tail] = form, env) do
    expand_quasiquote(form, env, 1)
  end

  def expand([{:sym, "define-record-type"} | tail], env) do
    expand_define_record_type(tail, env)
  end

  def expand([{:sym, "guard"} | tail], env), do: expand_guard(tail, env)

  def expand([{:sym, name} | _args] = form, env) do
    case lookup_with_fallback(env, name) do
      {:macro, transformer} ->
        new_form = transformer.(form)
        expand(new_form, env)

      {:special, base} ->
        # A core special form's name appeared with a hygiene mark.
        # Re-dispatch on the canonical name so the special-form
        # clauses above pick it up and emit canonical output.
        canonicalise_special(base, form, env)

      _ ->
        expand_application(form, env)
    end
  end

  def expand([_head | _tail] = form, env), do: expand_application(form, env)

  def expand({:sym, _} = sym, _env), do: sym
  def expand([], _env), do: []
  def expand(other, _env), do: other

  # ---------------------------------------------------------------------------
  # Special-form expanders
  # ---------------------------------------------------------------------------

  defp expand_application([head | args], env) do
    [expand(head, env) | expand_each(args, env)]
  end

  # A core special form's name reached us with a hygiene mark — i.e.
  # a template wrote one of `quote`/`if`/`lambda`/etc. without
  # listing it in `SyntaxRules`'s `@core_keywords`. Re-dispatch on
  # the canonical name so the dedicated handlers fire.
  defp canonicalise_special(base, [{:sym, _} | tail], env) do
    expand([{:sym, base} | tail], env)
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

  defp expand_each([], _env), do: []

  defp expand_each([h | t], env) do
    [expand(h, env) | expand_each(t, env)]
  end

  defp expand_each(other, _env), do: other

  defp expand_lambda([params_form | body], env) when body != [] do
    inner = SyntaxEnv.push_variables(env, collect_param_names(params_form))
    [{:sym, "lambda"} | [params_form | expand_each(body, inner)]]
  end

  defp expand_lambda(_, _env), do: raise(Error, reason: {:bad_special_form, "lambda"})

  defp collect_param_names({:sym, name}), do: [name]
  defp collect_param_names([]), do: []

  defp collect_param_names([{:sym, name} | rest]) do
    [name | collect_param_names(rest)]
  end

  defp collect_param_names(_), do: raise(Error, reason: {:bad_special_form, "lambda"})

  defp expand_define([{:sym, name} | [expr | []]], env) do
    [{:sym, "define"} | [{:sym, name} | [expand(expr, env) | []]]]
  end

  defp expand_define([[{:sym, name} | params] | body], env) when body != [] do
    inner = SyntaxEnv.push_variables(env, collect_param_names(params))
    expanded_body = expand_each(body, inner)

    [{:sym, "define"} | [[{:sym, name} | params] | expanded_body]]
  end

  defp expand_define(_, _env), do: raise(Error, reason: {:bad_special_form, "define"})

  # `define-values` is a core form rather than a `syntax-rules` macro
  # because, in internal-definition position, it has to fan out into
  # multiple recursive bindings on a single evaluation of the producer
  # — the body desugarer in `Schooner.Eval` handles that splice. The
  # expander only validates the formal-list shape and recursively
  # expands the producer expression.
  defp expand_define_values([formals | [producer | []]], env) do
    validate_define_values_formals(formals)
    [{:sym, "define-values"} | [formals | [expand(producer, env) | []]]]
  end

  defp expand_define_values(_, _env),
    do: raise(Error, reason: {:bad_special_form, "define-values"})

  defp validate_define_values_formals({:sym, _}), do: :ok
  defp validate_define_values_formals([]), do: :ok

  defp validate_define_values_formals([{:sym, _} | rest]),
    do: validate_define_values_formals(rest)

  defp validate_define_values_formals(_),
    do: raise(Error, reason: {:bad_special_form, "define-values"})

  defp expand_if([test | [then_e | []]], env) do
    [{:sym, "if"} | [expand(test, env) | [expand(then_e, env) | []]]]
  end

  defp expand_if([test | [then_e | [else_e | []]]], env) do
    [
      {:sym, "if"}
      | [expand(test, env) | [expand(then_e, env) | [expand(else_e, env) | []]]]
    ]
  end

  defp expand_if(_, _env), do: raise(Error, reason: {:bad_special_form, "if"})

  defp expand_letrec_star([bindings_form | body], env) when body != [] do
    parsed = parse_letrec_bindings(bindings_form, [])
    names = Enum.map(parsed, fn {sym, _} -> sym_name(sym) end)
    inner = SyntaxEnv.push_variables(env, names)

    expanded_bindings =
      parsed
      |> Enum.map(fn {sym, init} ->
        [sym | [expand(init, inner) | []]]
      end)
      |> Value.list()

    [{:sym, "letrec*"} | [expanded_bindings | expand_each(body, inner)]]
  end

  defp expand_letrec_star(_, _env), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  defp sym_name({:sym, name}), do: name

  # Single walk over the binding list yielding `[{sym, init}, ...]` —
  # used twice by the caller (once to derive the binder names for
  # the syntax-env shadow, once to expand the inits in that
  # already-shadowed env), avoiding the duplicate parse the previous
  # split into `letrec_binding_names/1` and `expand_letrec_bindings/2`
  # required.
  defp parse_letrec_bindings([], acc), do: Enum.reverse(acc)

  defp parse_letrec_bindings(
         [[{:sym, _} = sym | [init | []]] | rest],
         acc
       ) do
    parse_letrec_bindings(rest, [{sym, init} | acc])
  end

  defp parse_letrec_bindings(_, _),
    do: raise(Error, reason: {:bad_special_form, "letrec*"})

  # ---------------------------------------------------------------------------
  # define-record-type
  # ---------------------------------------------------------------------------

  # `define-record-type` is a core form rather than a macro because
  # it has to mint a fresh type identity at expansion time and embed
  # it as a literal in the bindings it generates — `syntax-rules`
  # templates are pure substitution and can't introduce a fresh
  # constant per use.
  defp expand_define_record_type(form, env) do
    {name, {ctor_name, ctor_fields}, pred_name, fields} = parse_record_type(form)
    type_id = fresh_record_type_id(name)
    field_names = Enum.map(fields, fn {fname, _accessor} -> fname end)

    defs = [
      record_constructor_def(ctor_name, ctor_fields, field_names, type_id),
      record_predicate_def(pred_name, type_id)
      | record_accessor_defs(fields, type_id)
    ]

    expand([{:sym, "begin"} | Value.list(defs)], env)
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

  # Build `(define (<name> <param> ...) <body>)`. Centralises the
  # `:pair`/`[]` skeleton the three record-machinery emitters
  # would otherwise duplicate.
  defp make_define_form(name, params, body) do
    Value.list([{:sym, "define"}, Value.list([{:sym, name} | params]), body])
  end

  # `guard` is a core form rather than a `syntax-rules` macro because
  # it must escape the body via Elixir `throw`/`catch` once a clause
  # matches — `call/cc` (phase 12) is the macro-friendly alternative
  # but does not yet exist. The expander walks the variable shadow,
  # the clause tests/bodies, and the body so that user macros inside
  # any of those positions get a chance to expand.
  defp expand_guard([[{:sym, var} | clauses_form] | body], env)
       when body != [] and is_binary(var) do
    inner = SyntaxEnv.push_variables(env, [var])
    expanded_clauses = expand_guard_clauses(clauses_form, inner)
    expanded_body = expand_each(body, env)

    [{:sym, "guard"} | [[{:sym, var} | expanded_clauses] | expanded_body]]
  end

  defp expand_guard(_, _env), do: raise(Error, reason: {:bad_special_form, "guard"})

  defp expand_guard_clauses([], _env), do: []

  defp expand_guard_clauses([clause | rest], env) do
    [expand_guard_clause(clause, env) | expand_guard_clauses(rest, env)]
  end

  defp expand_guard_clauses(_, _env), do: raise(Error, reason: {:bad_special_form, "guard"})

  # `else` clauses keep their literal head; everything after is a
  # body sequence that gets recursively expanded. `=>` clauses keep
  # the literal arrow and expand the test and the proc expression.
  # Bare `(test)` and `(test e1 e2 ...)` expand the test plus body.
  defp expand_guard_clause([{:sym, "else"} | body], env) when body != [] do
    [{:sym, "else"} | expand_each(body, env)]
  end

  defp expand_guard_clause([test | [{:sym, "=>"} | [proc | []]]], env) do
    [expand(test, env) | [{:sym, "=>"} | [expand(proc, env) | []]]]
  end

  defp expand_guard_clause([test | body], env) do
    [expand(test, env) | expand_each(body, env)]
  end

  defp expand_guard_clause(_, _env), do: raise(Error, reason: {:bad_special_form, "guard"})

  defp expand_let_syntax([bindings_form | body], env) when body != [] do
    bindings = parse_syntax_bindings(bindings_form, env, "let-syntax")
    inner = SyntaxEnv.push_macros(env, bindings)
    expanded = expand_each(body, inner)
    wrap_body_as_form("let-syntax", expanded)
  end

  defp expand_let_syntax(_, _env), do: raise(Error, reason: {:bad_special_form, "let-syntax"})

  defp expand_letrec_syntax([bindings_form | body], env) when body != [] do
    # Collect names first; compile transformers in an env that already
    # knows about all the new macro names so a transformer can refer to
    # its peers (mutually recursive macros).
    names = collect_macro_binding_names(bindings_form, "letrec-syntax")

    placeholder =
      Enum.map(
        names,
        &{&1, fn _ -> raise Error, reason: {:bad_special_form, "letrec-syntax"} end}
      )

    rec_env = SyntaxEnv.push_macros(env, placeholder)
    bindings = parse_syntax_bindings(bindings_form, rec_env, "letrec-syntax")
    inner = SyntaxEnv.push_macros(env, bindings)
    expanded = expand_each(body, inner)
    wrap_body_as_form("letrec-syntax", expanded)
  end

  defp expand_letrec_syntax(_, _env),
    do: raise(Error, reason: {:bad_special_form, "letrec-syntax"})

  defp wrap_body_as_form(_ctx, [single | []]), do: single
  defp wrap_body_as_form(_ctx, body), do: [{:sym, "begin"} | body]

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

  defp expand_quasiquote([{:sym, "quasiquote"} | [datum | []]], env, level) do
    [{:sym, "quasiquote"} | [walk_quasi(datum, env, level) | []]]
  end

  defp expand_quasiquote(_, _env, _level),
    do: raise(Error, reason: {:bad_special_form, "quasiquote"})

  defp walk_quasi([{:sym, "unquote"} | [expr | []]], env, 1) do
    [{:sym, "unquote"} | [expand(expr, env) | []]]
  end

  defp walk_quasi([{:sym, "unquote"} | [expr | []]], env, n) when n > 1 do
    [{:sym, "unquote"} | [walk_quasi(expr, env, n - 1) | []]]
  end

  defp walk_quasi([{:sym, "unquote-splicing"} | [expr | []]], env, 1) do
    [{:sym, "unquote-splicing"} | [expand(expr, env) | []]]
  end

  defp walk_quasi([{:sym, "unquote-splicing"} | [expr | []]], env, n) when n > 1 do
    [{:sym, "unquote-splicing"} | [walk_quasi(expr, env, n - 1) | []]]
  end

  defp walk_quasi([{:sym, "quasiquote"} | [expr | []]], env, n) do
    [{:sym, "quasiquote"} | [walk_quasi(expr, env, n + 1) | []]]
  end

  defp walk_quasi([h | t], env, level) do
    [walk_quasi(h, env, level) | walk_quasi(t, env, level)]
  end

  defp walk_quasi({:vector, t}, env, level) do
    new_items =
      0..(tuple_size(t) - 1)//1
      |> Enum.map(&walk_quasi(elem(t, &1), env, level))

    {:vector, List.to_tuple(new_items)}
  end

  defp walk_quasi(other, _env, _level), do: other
end
