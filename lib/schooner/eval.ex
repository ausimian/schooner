defmodule Schooner.Eval do
  @moduledoc """
  Tail-recursive direct evaluator for the core Scheme language.

  ## Tail-call invariant

  Every branch of `eval/2`, `apply_proc/2`, and `eval_sequence/2`
  finishes with a direct tail call to one of those three. Nothing
  wraps these calls in a `try`, a tuple constructor, a `with`, or any
  expression that would knock them out of tail position. This is what
  makes Scheme's proper-tail-call requirement fall out of BEAM's
  last-call optimisation. **Adding a wrapper around any of these
  calls breaks the invariant — see `eval_tco_test.exs`.**

  After phase 9 the evaluator only consumes the core forms produced
  by `Schooner.Expander`: `quote`, `if`, `lambda`, top-level
  `define`, `begin`, `letrec*`, `quasiquote`, application, and
  variable reference. Everything else (`cond`, `case`, the `let`
  family, `do`, `and`/`or`, `when`/`unless`) is a `syntax-rules`
  macro defined by the bootstrap; the throwaway evaluator branches
  for those forms have been removed.

  `letrec*` is retained as a core form rather than reduced to a
  macro because it backs both user-facing recursive bindings and
  internal-`define` splicing, and a fully-macroised replacement
  would need either mutation (which the value model does not
  permit) or a hand-built fix-point combinator.
  """

  alias Schooner.Env
  alias Schooner.Eval.Error
  alias Schooner.Eval.ExceptionState
  alias Schooner.Eval.ParameterState
  alias Schooner.Expander.SyntaxRules
  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  @doc """
  Coerce a multi-value to a single value. Auto-unwraps a 1-element
  `{:values, [v]}` to `v`; any other `{:values, vs}` raises
  `{:wrong_value_count, got, 1}`. Bare values pass through. Called at
  every single-value context — `call-with-values`'s producer return
  path is the only deliberate exception.
  """
  @spec single_value!(Value.t() | {:values, [Value.t()]}) :: Value.t()
  def single_value!({:values, [v]}), do: v

  def single_value!({:values, vs}) when is_list(vs) do
    raise PError, reason: {:wrong_value_count, length(vs), 1}
  end

  def single_value!(other), do: other

  @spec eval(Value.t(), Env.t()) :: Value.t()

  def eval({:sym, name}, env) do
    case Env.lookup(env, name) do
      {:ok, value} -> value
      {:uninitialised, n} -> raise Error, reason: {:rec_uninitialised, n}
      :error -> resolve_marked_var(env, name)
    end
  end

  def eval([], _env), do: raise(Error, reason: :empty_application)

  def eval([{:sym, "quote"} | tail], _env), do: eval_quote(tail)
  def eval([{:sym, "if"} | tail], env), do: eval_if(tail, env)
  def eval([{:sym, "lambda"} | tail], env), do: eval_lambda(tail, env)
  def eval([{:sym, "define"} | tail], env), do: eval_define(tail, env)
  def eval([{:sym, "begin"} | tail], env), do: eval_sequence(tail, env)
  def eval([{:sym, "letrec*"} | tail], env), do: eval_letrec_star(tail, env)
  def eval([{:sym, "quasiquote"} | tail], env), do: eval_quasiquote_top(tail, env)
  def eval([{:sym, "guard"} | tail], env), do: eval_guard(tail, env)
  def eval([head | tail], env), do: eval_apply(head, tail, env)

  def eval(value, _env), do: value

  # A name that carries a hygiene mark from a macro template but was
  # never bound by an introduced binder is a free reference to the
  # unmarked base name — usually a runtime primitive like `+`. Fall
  # back to the base name before declaring it unbound.
  defp resolve_marked_var(env, name) do
    with {:ok, base} <- SyntaxRules.strip_mark(name),
         {:ok, value} <- Env.lookup(env, base) do
      value
    else
      _ -> raise Error, reason: {:unbound, name}
    end
  end

  # ---------------------------------------------------------------------------
  # quote
  # ---------------------------------------------------------------------------

  defp eval_quote([datum | []]), do: datum
  defp eval_quote(_), do: raise(Error, reason: {:bad_special_form, "quote"})

  # ---------------------------------------------------------------------------
  # if
  # ---------------------------------------------------------------------------

  defp eval_if([test | [then_e | []]], env) do
    if eval_test(test, env), do: eval(then_e, env), else: :unspecified
  end

  defp eval_if([test | [then_e | [else_e | []]]], env) do
    if eval_test(test, env), do: eval(then_e, env), else: eval(else_e, env)
  end

  defp eval_if(_, _env), do: raise(Error, reason: {:bad_special_form, "if"})

  defp eval_test(test, env), do: Value.truthy?(single_value!(eval(test, env)))

  # ---------------------------------------------------------------------------
  # lambda
  # ---------------------------------------------------------------------------

  defp eval_lambda([_params_form | []], _env) do
    raise(Error, reason: {:bad_special_form, "lambda"})
  end

  defp eval_lambda([params_form | body], env) do
    Value.closure(parse_params(params_form), desugar_body(body), env, nil)
  end

  defp eval_lambda(_, _env), do: raise(Error, reason: {:bad_special_form, "lambda"})

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
  # define — top-level only at MVP; not enforced syntactically yet
  # ---------------------------------------------------------------------------

  defp eval_define([{:sym, name} | [expr | []]], env) do
    Env.define(env, name, single_value!(eval(expr, env)))
    :unspecified
  end

  defp eval_define([[{:sym, _name} | _params] | []], _env) do
    raise(Error, reason: {:bad_special_form, "define"})
  end

  defp eval_define([[{:sym, name} | params_form] | body], env) do
    closure = Value.closure(parse_params(params_form), desugar_body(body), env, name)
    Env.define(env, name, closure)
    :unspecified
  end

  defp eval_define(_, _env), do: raise(Error, reason: {:bad_special_form, "define"})

  # ---------------------------------------------------------------------------
  # sequence — body of begin / lambda / define-fn
  # ---------------------------------------------------------------------------

  defp eval_sequence([last | []], env), do: eval(last, env)

  defp eval_sequence([head | rest], env) do
    _ = eval(head, env)
    eval_sequence(rest, env)
  end

  defp eval_sequence([], _env), do: :unspecified

  # ---------------------------------------------------------------------------
  # application
  # ---------------------------------------------------------------------------

  defp eval_apply(head_expr, args_form, env) do
    proc = single_value!(eval(head_expr, env))
    args = eval_args(args_form, env, [])
    apply_proc(proc, args)
  end

  defp eval_args([], _env, acc), do: Enum.reverse(acc)

  defp eval_args([h | t], env, acc) do
    eval_args(t, env, [single_value!(eval(h, env)) | acc])
  end

  defp eval_args(_, _env, _acc), do: raise(Error, reason: :improper_application)

  @spec apply_proc(Value.t(), [Value.t()]) :: Value.t()
  def apply_proc({:closure, params, body, env, name}, args) do
    new_env = Env.extend(env, bind_params(params, args, name))
    eval_sequence(body, new_env)
  end

  def apply_proc({:primitive, name, arity, fun}, args) do
    check_primitive_arity!(arity, args, name)
    fun.(args)
  end

  def apply_proc({:parameter, id, init, _converter}, []) do
    ParameterState.lookup(id, init)
  end

  def apply_proc({:parameter, _, _, _}, args) do
    raise Error, reason: {:arity_mismatch, "parameter", {:exact, 0}, length(args)}
  end

  def apply_proc(other, _args), do: raise(Error, reason: {:not_a_procedure, other})

  defp bind_params({:fixed, n, names}, args, fname) do
    case length(args) do
      ^n -> Enum.zip(names, args)
      got -> raise(Error, reason: {:arity_mismatch, fname, {:exact, n}, got})
    end
  end

  defp bind_params({:any, name}, args, _fname), do: [{name, Value.list(args)}]

  defp bind_params({:fixed_rest, n, names, rest_name}, args, fname) do
    case length(args) do
      got when got >= n ->
        {head, tail} = Enum.split(args, n)
        Enum.zip(names, head) ++ [{rest_name, Value.list(tail)}]

      got ->
        raise(Error, reason: {:arity_mismatch, fname, {:at_least, n}, got})
    end
  end

  defp check_primitive_arity!(n, args, name) when is_integer(n) do
    got = length(args)

    if got != n do
      raise(Error, reason: {:arity_mismatch, name, {:exact, n}, got})
    end
  end

  defp check_primitive_arity!({:at_least, n}, args, name) do
    got = length(args)

    if got < n do
      raise(Error, reason: {:arity_mismatch, name, {:at_least, n}, got})
    end
  end

  defp check_primitive_arity!({:between, lo, hi}, args, name) do
    got = length(args)

    if got < lo or got > hi do
      raise(Error, reason: {:arity_mismatch, name, {:between, lo, hi}, got})
    end
  end

  # `letrec*` is the workhorse for both user-facing recursive bindings
  # (the `let`, `let*`, `letrec`, `letrec*`, named-`let` bootstrap
  # macros all expand to it eventually) and for internal-define
  # splicing (see `desugar_body/1`). Init expressions are evaluated
  # left-to-right in a frame whose closure values reference the
  # frame's identity — `Env.extend_rec/2` plus `rec_set/3` ties the
  # knot without any after-the-fact mutation of the closures
  # themselves.
  defp eval_letrec_star([bindings_form | body], env) when body != [] do
    {names, inits} = parse_bindings(bindings_form, "letrec*")
    rec_env = Env.extend_rec(env, names)

    with_rec_frame(rec_env, fn ->
      names
      |> Enum.zip(inits)
      |> Enum.each(fn {name, init} ->
        Env.rec_set(rec_env, name, single_value!(eval(init, rec_env)))
      end)

      eval_body(body, rec_env)
    end)
  end

  defp eval_letrec_star(_, _env), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  defp parse_bindings(form, ctx), do: parse_bindings(form, ctx, [], [])

  defp parse_bindings([], _ctx, names, inits) do
    {Enum.reverse(names), Enum.reverse(inits)}
  end

  defp parse_bindings([[{:sym, name} | [init | []]] | rest], ctx, ns, is) do
    parse_bindings(rest, ctx, [name | ns], [init | is])
  end

  defp parse_bindings(_, ctx, _, _), do: raise(Error, reason: {:bad_special_form, ctx})

  # `unquote` and `unquote-splicing` only fire at quasi level 1; nested
  # `quasiquote` raises the level, nested `unquote` lowers it.
  defp eval_quasiquote_top([datum | []], env) do
    quasi(datum, env, 1)
  end

  defp eval_quasiquote_top(_, _env), do: raise(Error, reason: {:bad_special_form, "quasiquote"})

  defp quasi([{:sym, "unquote"} | [expr | []]], env, 1), do: eval(expr, env)

  defp quasi([{:sym, "unquote"} | [expr | []]], env, n) when n > 1 do
    Value.list([Value.symbol("unquote"), quasi(expr, env, n - 1)])
  end

  defp quasi([{:sym, "quasiquote"} | [expr | []]], env, n) do
    Value.list([Value.symbol("quasiquote"), quasi(expr, env, n + 1)])
  end

  defp quasi([head | tail], env, level) do
    case head do
      [{:sym, "unquote-splicing"} | [expr | []]] when level == 1 ->
        spliced = eval(expr, env)
        rest = quasi(tail, env, level)
        splice_append(spliced, rest, "unquote-splicing")

      _ ->
        [quasi(head, env, level) | quasi(tail, env, level)]
    end
  end

  defp quasi({:vector, t}, env, level) do
    list = Value.list(Tuple.to_list(t))
    Value.vector(scheme_list_to_elixir(quasi(list, env, level)))
  end

  defp quasi(other, _env, _level), do: other

  defp splice_append([], rest, _ctx), do: rest

  defp splice_append([h | t], rest, ctx) do
    [h | splice_append(t, rest, ctx)]
  end

  defp splice_append(_, _, ctx), do: raise(Error, reason: {:bad_special_form, ctx})

  defp scheme_list_to_elixir([]), do: []
  defp scheme_list_to_elixir([h | t]), do: [h | scheme_list_to_elixir(t)]

  # ---------------------------------------------------------------------------
  # Internal definitions / body splicing
  # ---------------------------------------------------------------------------

  # `eval_body/2` is the entry point for evaluating any r7rs body
  # (lambda, let-family, when/unless, cond/case clauses): it splices
  # leading internal defines into a `letrec*` and then evaluates the
  # resulting sequence. Lambda bodies are pre-desugared at closure
  # creation time so per-application cost stays at zero.
  defp eval_body(body, env), do: eval_sequence(desugar_body(body), env)

  # Run `body_fun` and release `rec_env`'s recursive frame on every
  # exit path. The body's tail-recursive calls bounce through
  # `eval`/`eval_sequence`/`apply_proc` and never return through this
  # frame, so TCO across the body is preserved — see `eval_tco_test`.
  defp with_rec_frame(rec_env, body_fun) do
    body_fun.()
  after
    Env.release_rec(rec_env)
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
    scan_defines(splice_append(inner, rest, "begin"), acc)
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
        {name, expr}

      [[{:sym, name} | params] | body_forms] when body_forms != [] ->
        {name, [{:sym, "lambda"} | [params | body_forms]]}

      _ ->
        raise(Error, reason: {:bad_special_form, "define"})
    end
  end

  defp parse_internal_define(_), do: nil

  defp check_no_more_defines([]), do: :ok

  defp check_no_more_defines([[{:sym, "begin"} | inner] | rest]) do
    check_no_more_defines(splice_append(inner, rest, "begin"))
  end

  defp check_no_more_defines([form | rest]) do
    if parse_internal_define(form) != nil do
      raise(Error, reason: :define_after_expression)
    else
      check_no_more_defines(rest)
    end
  end

  defp build_letrec_bindings([]), do: []

  defp build_letrec_bindings([{name, init} | rest]) do
    binding = [{:sym, name} | [init | []]]
    [binding | build_letrec_bindings(rest)]
  end

  # ---------------------------------------------------------------------------
  # guard
  # ---------------------------------------------------------------------------

  # `guard` is a core form rather than a `syntax-rules` macro because
  # it has to escape the body once a clause matches, and the only
  # tools available pre-`call/cc` (phase 12) are Elixir `throw` /
  # `catch`. The handler is wrapped as a `:primitive` so
  # `apply_proc/2` invokes it with the same machinery as a user
  # handler — `with-exception-handler` and `guard` are
  # indistinguishable from the raise side.
  defp eval_guard([[{:sym, var} | clauses_form] | body], env)
       when is_binary(var) and body != [] do
    tag = make_ref()
    handler = build_guard_handler(var, clauses_form, env, tag)
    # Snapshot/restore the whole stack rather than `pop`ing once in
    # the after-clause: by the time we exit (matched-and-thrown,
    # re-raised, or normal-return) the handler may already have been
    # popped by `ExceptionState.raise_value/1`, and a blind pop
    # would discard an outer handler we didn't install.
    prev = ExceptionState.snapshot()
    ExceptionState.push(handler)

    try do
      eval_body(body, env)
    catch
      :throw, {:schooner_guard, ^tag, value} -> value
    after
      ExceptionState.restore(prev)
    end
  end

  defp eval_guard(_, _env), do: raise(Error, reason: {:bad_special_form, "guard"})

  defp build_guard_handler(var, clauses_form, env, tag) do
    Value.primitive("%guard-handler", 1, fn [raised] ->
      handler_env = Env.extend(env, [{var, raised}])

      case eval_guard_clauses(clauses_form, handler_env) do
        {:matched, value} -> throw({:schooner_guard, tag, value})
        :no_match -> ExceptionState.raise_value(raised)
      end
    end)
  end

  defp eval_guard_clauses([], _env), do: :no_match

  defp eval_guard_clauses([[{:sym, "else"} | body] | _rest], env)
       when body != [] do
    {:matched, eval_body(body, env)}
  end

  defp eval_guard_clauses([clause | rest], env) do
    case eval_guard_clause(clause, env) do
      :no_match -> eval_guard_clauses(rest, env)
      {:matched, _} = m -> m
    end
  end

  defp eval_guard_clauses(_, _env), do: raise(Error, reason: {:bad_special_form, "guard"})

  defp eval_guard_clause([test | []], env) do
    case eval(test, env) do
      false -> :no_match
      val -> {:matched, val}
    end
  end

  defp eval_guard_clause([test | [{:sym, "=>"} | [proc_expr | []]]], env) do
    case eval(test, env) do
      false ->
        :no_match

      val ->
        proc = eval(proc_expr, env)
        {:matched, apply_proc(proc, [val])}
    end
  end

  defp eval_guard_clause([test | body], env) when body != [] do
    case eval(test, env) do
      false -> :no_match
      _ -> {:matched, eval_body(body, env)}
    end
  end

  defp eval_guard_clause(_, _env), do: raise(Error, reason: {:bad_special_form, "guard"})
end
