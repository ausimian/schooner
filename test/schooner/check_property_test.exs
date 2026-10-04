defmodule Schooner.CheckPropertyTest do
  # A script that runs successfully must not get an `:error` diagnostic
  # from `Schooner.check/3` under the same environment.
  #
  # The generator builds scripts whose every reference is in scope and
  # whose every call has the right argument count, using the binding
  # forms the checker has to see through: `let`, `let*`, `letrec`,
  # named `let`, `do`, `lambda`, `case-lambda`, `guard`,
  # `parameterize`, internal and top-level `define`, `define-values`,
  # `define-record-type`, and macros whose templates introduce names
  # (`tmp`, `t`) that the script also uses. Local names shadow
  # primitives (`car`, `not`) with procedures of other arities. Each
  # script is run first, so a generator mistake fails the property
  # instead of passing it vacuously.

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Schooner.Environment

  @prelude """
  (import (scheme base) (scheme case-lambda))
  (define-syntax swap-pair (syntax-rules () ((_ a b) (let ((tmp a)) (list b tmp)))))
  (define-syntax my-or (syntax-rules () ((_ a b) (let ((t a)) (if t t b)))))
  (define-record-type box (make-box v) box? (v box-v))
  (define param (make-parameter 0))
  """

  # Procedures in scope at the start, with their arities.
  @globals %{
    "list" => {:proc, :any},
    "vector" => {:proc, :any},
    "cons" => {:proc, 2},
    "not" => {:proc, 1},
    "eq?" => {:proc, 2},
    "equal?" => {:proc, 2},
    "null?" => {:proc, 1},
    "make-box" => {:proc, 1},
    "box?" => {:proc, 1},
    "param" => {:proc, 0}
  }

  @values ~w(a b x tmp t)
  @procs ~w(f g car not)
  @top_values ~w(g1 g2 tmp t)

  defp environment, do: Environment.new()

  property "a script that runs successfully gets no errors from check/3" do
    check all(body <- program(), max_runs: 300) do
      source = @prelude <> body
      assert {:ok, _} = Schooner.eval(source, environment())
      assert Enum.filter(Schooner.check(source, environment()), &(&1.severity == :error)) == []
    end
  end

  # ---------------------------------------------------------------------------
  # Top level
  # ---------------------------------------------------------------------------

  defp program, do: integer(1..6) |> bind(&top_forms(&1, @globals))

  defp top_forms(0, scope), do: map(expr(scope, 2), &(&1 <> "\n"))

  defp top_forms(n, scope) do
    one_of([
      top_define_value(scope),
      top_define_proc(scope),
      top_define_values(scope),
      map(expr(scope, 3), &{&1, scope})
    ])
    |> bind(fn {form, scope} -> map(top_forms(n - 1, scope), &(form <> "\n" <> &1)) end)
  end

  defp top_define_value(scope) do
    bind(member_of(@top_values), fn name ->
      map(expr(scope, 2), &{"(define #{name} #{&1})", Map.put(scope, name, :value)})
    end)
  end

  # The procedure is not in scope in its own body, so it never recurses.
  defp top_define_proc(scope) do
    bind({member_of(~w(gf gh)), params()}, fn {name, params} ->
      body_scope = scope |> Map.delete(name) |> bind_values(params)

      map(body(body_scope, 2), fn body ->
        {"(define (#{name}#{spaced(params)}) #{body})",
         Map.put(scope, name, {:proc, length(params)})}
      end)
    end)
  end

  defp top_define_values(scope) do
    map({expr(scope, 1), expr(scope, 1)}, fn {e1, e2} ->
      {"(define-values (dv1 dv2) (values #{e1} #{e2}))",
       scope |> Map.put("dv1", :value) |> Map.put("dv2", :value)}
    end)
  end

  # A body: up to two internal definitions, then an expression. The
  # definitions form a `letrec*`, so the names they bind are hidden
  # from the outer scope until each is defined.
  defp body(scope, depth) do
    bind(list_of(definition_head(), max_length: 2), fn heads ->
      heads = Enum.uniq_by(heads, &elem(&1, 0))
      hidden = Map.drop(scope, Enum.map(heads, &elem(&1, 0)))

      {defs, inner} =
        Enum.map_reduce(heads, hidden, fn head, s ->
          {definition(head, s, depth - 1), define(s, head)}
        end)

      map({fixed_list(defs), expr(inner, depth)}, fn {defs, e} -> Enum.join(defs ++ [e], " ") end)
    end)
  end

  defp definition_head do
    one_of([map(member_of(@values), &{&1, :value}), tuple({member_of(@procs), params()})])
  end

  defp definition({name, :value}, scope, depth),
    do: map(expr(scope, depth), &"(define #{name} #{&1})")

  defp definition({name, params}, scope, depth) do
    map(expr(bind_values(scope, params), depth), fn body ->
      "(define (#{name}#{spaced(params)}) #{body})"
    end)
  end

  defp define(scope, {name, :value}), do: Map.put(scope, name, :value)
  defp define(scope, {name, params}), do: Map.put(scope, name, {:proc, length(params)})

  # ---------------------------------------------------------------------------
  # Expressions
  # ---------------------------------------------------------------------------

  defp expr(scope, depth) when depth <= 0, do: leaf(scope)

  defp expr(scope, depth) do
    d = depth - 1

    frequency([
      {3, leaf(scope)},
      {4, call(scope, d)},
      {1, let_form("let", scope, d)},
      {1, let_form("let*", scope, d)},
      {1, local_proc(scope, d)},
      {1, letrec_form(scope, d)},
      {1, named_let(scope, d)},
      {1, do_loop(scope, d)},
      {1, applied_lambda(scope, d)},
      {1, applied_case_lambda(scope, d)},
      {1, guard_form(scope, d)},
      {1, map(expr(scope, d), &"(parameterize ((param #{&1})) (list (param) param))")},
      {1, map({expr(scope, d), expr(scope, d)}, fn {a, b} -> "(swap-pair #{a} #{b})" end)},
      {1, map({expr(scope, d), expr(scope, d)}, fn {a, b} -> "(my-or #{a} #{b})" end)},
      {1, map(expr(scope, d), &"(box-v (make-box #{&1}))")},
      {1, derived(scope, d)},
      {1, map({expr(scope, d), expr(scope, d)}, fn {a, b} -> "`(1 ,#{a} ,@(list #{b}))" end)}
    ])
  end

  defp leaf(scope) do
    names = Map.keys(scope)
    one_of([integer(0..9) |> map(&Integer.to_string/1), constant("'sym"), member_of(names)])
  end

  defp call(scope, depth) do
    case for {name, {:proc, arity}} <- scope, do: {name, arity} do
      [] -> leaf(scope)
      procs -> bind(member_of(procs), &call_to(&1, scope, depth))
    end
  end

  defp call_to({name, :any}, scope, depth),
    do: bind(integer(0..3), &call_to({name, &1}, scope, depth))

  defp call_to({name, n}, scope, depth), do: map(args(scope, depth, n), &"(#{name}#{&1})")

  defp args(scope, depth, n),
    do: map(fixed_list(List.duplicate(expr(scope, depth), n)), &spaced/1)

  defp let_form(keyword, scope, depth) do
    bind(names(), fn names ->
      {inits, _} = Enum.map_reduce(names, scope, &let_init(keyword, &1, &2, scope, depth))

      map({fixed_list(inits), body(bind_values(scope, names), depth)}, fn {bindings, body} ->
        "(#{keyword} (#{Enum.join(bindings, " ")}) #{body})"
      end)
    end)
  end

  # `let*` inits see the earlier names; `let` inits see none of them.
  defp let_init(keyword, name, seen, scope, depth) do
    init_scope = if keyword == "let*", do: seen, else: scope
    {map(expr(init_scope, depth), &"(#{name} #{&1})"), Map.put(seen, name, :value)}
  end

  # A local procedure, possibly shadowing a primitive with another arity.
  defp local_proc(scope, depth) do
    bind({member_of(@procs), params()}, fn {name, params} ->
      fbody = expr(bind_values(scope, params), depth)
      rest = body(Map.put(scope, name, {:proc, length(params)}), depth)

      map({fbody, rest}, fn {fbody, rest} ->
        "(let ((#{name} (lambda (#{Enum.join(params, " ")}) #{fbody}))) #{rest})"
      end)
    end)
  end

  defp letrec_form(scope, depth) do
    bind(params(), fn params ->
      fbody = expr(bind_values(scope, params), depth)
      call = args(scope, depth, length(params))

      map({fbody, call}, fn {fbody, call} ->
        "(letrec ((lr (lambda (#{Enum.join(params, " ")}) #{fbody}))) (lr#{call}))"
      end)
    end)
  end

  # The loop is only called from a branch that never runs.
  defp named_let(scope, depth) do
    bind(names(), fn names ->
      inits =
        fixed_list(Enum.map(names, fn name -> map(expr(scope, depth), &"(#{name} #{&1})") end))

      inner = bind_values(scope, names)

      map({inits, expr(inner, depth), args(inner, depth, length(names))}, fn
        {bindings, body, again} ->
          "(let lp (#{Enum.join(bindings, " ")}) (if #t #{body} (lp#{again})))"
      end)
    end)
  end

  defp do_loop(scope, depth) do
    map(expr(Map.put(scope, "i", :value), depth), fn body ->
      "(do ((i 0 (+ i 1))) ((= i 2) #{body}))"
    end)
  end

  defp applied_lambda(scope, depth) do
    bind(params(), fn params ->
      map({expr(bind_values(scope, params), depth), args(scope, depth, length(params))}, fn
        {body, call} -> "((lambda (#{Enum.join(params, " ")}) #{body})#{call})"
      end)
    end)
  end

  defp applied_case_lambda(scope, depth) do
    one = expr(Map.put(scope, "a", :value), depth)
    two = expr(scope |> Map.put("a", :value) |> Map.put("b", :value), depth)

    bind(integer(1..2), fn n ->
      map({one, two, args(scope, depth, n)}, fn {one, two, call} ->
        "((case-lambda ((a) #{one}) ((a b) #{two}))#{call})"
      end)
    end)
  end

  defp guard_form(scope, depth) do
    handler = expr(Map.put(scope, "c", :value), depth)
    body = one_of([expr(scope, depth), map(expr(scope, depth), &"(raise #{&1})")])

    map({handler, body}, fn {handler, body} ->
      "(guard (c ((symbol? c) (list c #{handler})) (else c)) #{body})"
    end)
  end

  defp derived(scope, depth) do
    e = expr(scope, depth)

    one_of([
      map({e, e}, fn {a, b} -> "(when #{a} #{b})" end),
      map({e, e}, fn {a, b} -> "(unless #{a} #{b})" end),
      map({e, e, e}, fn {a, b, c} -> "(cond ((null? #{a}) #{b}) (else #{c}))" end),
      map({e, e, e}, fn {a, b, c} -> "(case #{a} ((1 2) #{b}) (else #{c}))" end),
      map({e, e}, fn {a, b} -> "(and #{a} #{b})" end),
      map({e, e}, fn {a, b} -> "(or #{a} #{b})" end)
    ])
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp params, do: map(integer(0..3), &Enum.take(~w(p q r), &1))

  defp names, do: map(list_of(member_of(@values), min_length: 1, max_length: 2), &Enum.uniq/1)

  defp bind_values(scope, names), do: Enum.reduce(names, scope, &Map.put(&2, &1, :value))

  defp spaced(items), do: Enum.map_join(items, &(" " <> &1))
end
