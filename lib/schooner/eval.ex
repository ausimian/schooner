defmodule Schooner.Eval do
  @moduledoc """
  Tail-recursive direct evaluator for the core Scheme language.

  `eval/2` takes a core form as produced by `Schooner.Expander` and
  runs it through `Schooner.Eval.Analyze`, which rewrites the
  s-expression into a tagged IR with every variable reference
  resolved. `compile/2` then turns that IR into a tree of Elixir
  closures — one `fn env -> ... end` per node, built once — so
  executing a program is a chain of closure calls with no per-node
  dispatch. `Schooner.compile/2` stores the analysed IR (plain data,
  safe to cache or persist) and `Schooner.run_compiled/2` compiles it
  to closures on each run.

  ## Tail-call invariant

  Every compiled closure and every `apply_proc/2` clause finishes with
  a direct tail call: the closure for a node in tail position calls
  the next closure (or `apply_proc/2`) last, and `apply_proc/2` calls
  a closure's compiled body last. Nothing wraps these calls in a
  `try`, a tuple constructor, a `with`, or any expression that would
  knock them out of tail position. This is what makes Scheme's
  proper-tail-call requirement fall out of BEAM's last-call
  optimisation. **Adding a wrapper around any of these calls breaks
  the invariant — see `eval_tco_test.exs`.**

  The evaluator only consumes the core forms produced by
  `Schooner.Expander`: `quote`, `if`, `lambda`, top-level `define`,
  `define-values`, `begin`, `letrec*`, `quasiquote`, `guard`,
  application, and variable reference. Everything else (`cond`,
  `case`, the `let` family, `do`, `and`/`or`, `when`/`unless`) is a
  `syntax-rules` macro defined by the bootstrap.

  `letrec*` is retained as a core form rather than reduced to a
  macro because it backs both user-facing recursive bindings and
  internal-`define` splicing, and a fully-macroised replacement
  would need either mutation (which the value model does not
  permit) or a hand-built fix-point combinator.
  """

  alias Schooner.Env
  alias Schooner.Eval.Analyze
  alias Schooner.Eval.Error
  alias Schooner.Eval.ExceptionState
  alias Schooner.Eval.ParameterState
  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Primitives.Base
  alias Schooner.Value

  @rec_uninitialised Env.rec_uninitialised()
  @unbound Env.unbound()

  @doc """
  Coerce a multi-value to a single value. Auto-unwraps a 1-element
  `{:values, [v]}` to `v`; any other `{:values, vs}` raises
  `{:wrong_value_count, got, 1}`. Bare values pass through. Called at
  every single-value context — `call-with-values`'s producer return
  path is the only deliberate exception.
  """
  @typedoc """
  Result of `eval/2` and `apply_proc/2`: either a regular value or
  the multi-value transit marker `{:values, vs}` produced by
  `(values ...)` and consumed only by `call-with-values` /
  `single_value!/1`.
  """
  @type eval_result :: Value.t() | {:values, [Value.t()]}

  # Called for every argument and procedure head, so inline it into
  # the compiled closures.
  @compile {:inline, single_value!: 1}
  @spec single_value!(eval_result()) :: Value.t()
  def single_value!({:values, [v]}), do: v

  def single_value!({:values, vs}) when is_list(vs) do
    raise PError, reason: {:wrong_value_count, length(vs), 1}
  end

  def single_value!(other), do: other

  @typedoc "A compiled IR node: run it against an env to evaluate it."
  @type code :: (Env.t() -> eval_result())

  @doc """
  Analyse and evaluate a single top-level core form.

  Variable references are resolved against the empty lexical scope, so
  `env` must have no lexical frames (an env from `Env.new/0` or a
  `Schooner.Environment`).
  """
  @spec eval(Value.t(), Env.t()) :: eval_result()
  def eval(form, %Env{lex: []} = env), do: compile(Analyze.analyze(form), env.globals).(env)

  @doc """
  Compile and evaluate an IR node produced by
  `Schooner.Eval.Analyze.analyze/1`.
  """
  @spec exec(Analyze.ir(), Env.t()) :: eval_result()
  def exec(ir, %Env{globals: g} = env), do: compile(ir, g).(env)

  @doc """
  Compile an IR node into a closure that evaluates it against an env
  whose globals slot is `globals`. Child nodes are compiled up front,
  so the returned closure does no further dispatch on the IR, and
  global references are bound to their cells in `globals`.
  """
  @spec compile(Analyze.ir(), reference()) :: code()
  def compile({:const, value}, _g), do: fn _env -> value end

  # The two shallowest depths cover almost every reference, so match
  # the frame directly instead of walking the chain.
  def compile({:lref, 0, index}, _g), do: fn %Env{lex: [frame | _]} -> elem(frame, index) end
  def compile({:lref, 1, index}, _g), do: fn %Env{lex: [_, frame | _]} -> elem(frame, index) end

  def compile({:lref, depth, index}, _g),
    do: fn %Env{lex: lex} -> elem(frame_at(lex, depth), index) end

  def compile({:rref, depth, slot, name, fallback}, g) do
    fallback = compile(fallback, g)

    fn %Env{lex: lex} = env ->
      {:rec, ref} = frame_at(lex, depth)

      case :erlang.get(ref) do
        {:rec_frame, _names, values} -> rec_value!(elem(values, slot), name)
        :undefined -> fallback.(env)
      end
    end
  end

  # An unmarked global reads its cell (see `Schooner.Env`), resolved
  # here once. A marked name is still looked up by name: macro
  # expansion mints fresh marked names, and giving each one a cell
  # would grow the globals with every expansion.
  def compile({:gref, name, nil}, g) do
    cell = Env.global_cell(g, name)

    fn _env ->
      case :erlang.get(cell) do
        @unbound -> raise Error, reason: {:unbound, name}
        value -> value
      end
    end
  end

  def compile({:gref, name, marked}, _g) do
    fn env ->
      case Env.fetch_global(env, name) do
        {:ok, value} -> value
        :error -> resolve_marked_var(marked, name, env)
      end
    end
  end

  def compile({:if, test, then_e, else_e}, g) do
    test = compile(test, g)
    then_c = compile(then_e, g)
    else_c = compile(else_e, g)

    fn env ->
      case single_value!(test.(env)) do
        false -> else_c.(env)
        _ -> then_c.(env)
      end
    end
  end

  # A two-argument call through an unmarked global named like one of
  # the inlined arithmetic or comparison primitives. The global's cell
  # is still read on every call, so a redefinition is honoured (and a
  # lexical binding never reaches this clause); the integer operation
  # runs inline only when the cell holds the standard procedure.
  def compile({:app, {:gref, name, nil}, [a, b]} = node, g) do
    case Map.fetch(Base.inlined(), name) do
      {:ok, fun} -> compile_inline(name, fun, Env.global_cell(g, name), a, b, g)
      :error -> compile_app(node, g)
    end
  end

  def compile({:app, _head, _args} = node, g), do: compile_app(node, g)

  def compile({:lambda, params, {names, body}, name}, g) do
    body = compile_body(body, g)
    fn env -> Value.closure(params, {names, body}, env, name) end
  end

  def compile({:define, name, expr}, g) do
    expr = compile(expr, g)

    fn env ->
      Env.define(env, name, single_value!(expr.(env)))
      :unspecified
    end
  end

  def compile({:define_values, spec, expr}, g) do
    expr = compile(expr, g)
    fn env -> eval_define_values(spec, expr, env) end
  end

  def compile({:seq, body}, g), do: compile_body(body, g)

  def compile({:letrec, names, bindings, body}, g) do
    bindings = Enum.map(bindings, &compile_binding(&1, g))
    body = compile_body(body, g)
    fn env -> eval_letrec_star(names, bindings, body, env) end
  end

  # A `letrec*` whose lambdas are only ever called directly (see
  # `Schooner.Eval.Analyze`) never materialises them as closures. Its
  # frame is `{{}, body_0, body_1, ...}`: an empty names tuple, so
  # by-name lookup passes over it, followed by each lambda's compiled
  # body. The frame is built once, here.
  def compile({:fixrec, lambdas, body}, g) do
    frame = List.to_tuple([{} | Enum.map(lambdas, fn {_names, b} -> compile_body(b, g) end)])
    body = compile_body(body, g)
    fn %Env{lex: lex} = env -> body.(%{env | lex: [frame | lex]}) end
  end

  # A direct call to lambda `slot` of the `:fixrec` frame `depth`
  # levels up. The callee's frame goes on top of the `:fixrec` frame,
  # exactly where `apply_proc/2` would have put it on top of the
  # closure's env, and the compiled body is tail-called.
  def compile({:known_call, depth, slot, names, args}, g) do
    index = slot + 1

    case Enum.map(args, &compile(&1, g)) do
      [a] ->
        fn %Env{lex: lex} = env ->
          x = single_value!(a.(env))
          [fix | _] = rest = drop_frames(lex, depth)
          elem(fix, index).(%{env | lex: [{names, x} | rest]})
        end

      [a, b] ->
        fn %Env{lex: lex} = env ->
          x = single_value!(a.(env))
          y = single_value!(b.(env))
          [fix | _] = rest = drop_frames(lex, depth)
          elem(fix, index).(%{env | lex: [{names, x, y} | rest]})
        end

      [a, b, c] ->
        fn %Env{lex: lex} = env ->
          x = single_value!(a.(env))
          y = single_value!(b.(env))
          z = single_value!(c.(env))
          [fix | _] = rest = drop_frames(lex, depth)
          elem(fix, index).(%{env | lex: [{names, x, y, z} | rest]})
        end

      codes ->
        fn %Env{lex: lex} = env ->
          frame = List.to_tuple([names | eval_args(codes, env)])
          [fix | _] = rest = drop_frames(lex, depth)
          elem(fix, index).(%{env | lex: [frame | rest]})
        end
    end
  end

  def compile({:quasi, template}, g), do: compile_template(template, g)

  def compile({:guard, names, clauses, body}, g) do
    clauses = Enum.map(clauses, &compile_guard_clause(&1, g))
    body = compile_body(body, g)
    fn env -> eval_guard(names, clauses, body, env) end
  end

  def compile({:raise, exception}, _g), do: fn _env -> raise(exception) end

  # One clause per inlined primitive, so each closure carries its own
  # BEAM operator. Head first, then arguments left to right, as for any
  # application; anything but the standard procedure applied to two
  # integers takes the ordinary `apply_proc/2` path.
  for {name, op} <- [
        {"+", :+},
        {"-", :-},
        {"*", :*},
        {"=", :"=:="},
        {"<", :<},
        {">", :>},
        {"<=", :"=<"},
        {">=", :>=}
      ] do
    defp compile_inline(unquote(name), fun, cell, a, b, g) do
      a = compile(a, g)
      b = compile(b, g)

      fn env ->
        proc =
          case :erlang.get(cell) do
            @unbound -> raise Error, reason: {:unbound, unquote(name)}
            value -> value
          end

        x = single_value!(a.(env))
        y = single_value!(b.(env))

        case proc do
          {:primitive, _, _, ^fun} when is_integer(x) and is_integer(y) ->
            :erlang.unquote(op)(x, y)

          _ ->
            apply_proc(proc, [x, y])
        end
      end
    end
  end

  # Applications are specialised on argument count so the common small
  # arities build their argument list inline. Head first, then
  # arguments left to right.
  defp compile_app({:app, head, args}, g) do
    head = compile(head, g)

    case Enum.map(args, &compile(&1, g)) do
      [] ->
        fn env -> apply_proc(single_value!(head.(env)), []) end

      [a] ->
        fn env ->
          proc = single_value!(head.(env))
          apply_proc(proc, [single_value!(a.(env))])
        end

      [a, b] ->
        fn env ->
          proc = single_value!(head.(env))
          x = single_value!(a.(env))
          apply_proc(proc, [x, single_value!(b.(env))])
        end

      [a, b, c] ->
        fn env ->
          proc = single_value!(head.(env))
          x = single_value!(a.(env))
          y = single_value!(b.(env))
          apply_proc(proc, [x, y, single_value!(c.(env))])
        end

      codes ->
        fn env ->
          proc = single_value!(head.(env))
          apply_proc(proc, eval_args(codes, env))
        end
    end
  end

  # A body (or `begin`) compiles to one closure that runs each form in
  # order and tail-calls the last.
  defp compile_body([], _g), do: fn _env -> :unspecified end
  defp compile_body([last], g), do: compile(last, g)

  defp compile_body([head | rest], g) do
    head = compile(head, g)
    rest = compile_body(rest, g)

    fn env ->
      _ = head.(env)
      rest.(env)
    end
  end

  defp compile_binding({:single, slot, init}, g), do: {:single, slot, compile(init, g)}

  defp compile_binding({:multi, spec, init, slots}, g),
    do: {:multi, spec, compile(init, g), slots}

  # A name that carries a hygiene mark from a macro template but was
  # never bound by an introduced binder is a free reference to the
  # unmarked base name — usually a runtime primitive like `+`. The
  # analyser pre-resolved that base name; any failure to find it
  # (unbound, or an uninitialised letrec slot) reports the original
  # marked name as unbound.
  defp resolve_marked_var(nil, name, _env), do: raise(Error, reason: {:unbound, name})

  defp resolve_marked_var(base_ref, name, env) do
    case lookup_soft(base_ref, env) do
      {:ok, value} -> value
      :error -> raise Error, reason: {:unbound, name}
    end
  end

  defp lookup_soft({:lref, depth, index}, %Env{lex: lex}),
    do: {:ok, elem(frame_at(lex, depth), index)}

  defp lookup_soft({:rref, depth, slot, _name, fallback}, %Env{lex: lex} = env) do
    {:rec, ref} = frame_at(lex, depth)

    case :erlang.get(ref) do
      {:rec_frame, _names, values} ->
        case elem(values, slot) do
          @rec_uninitialised -> :error
          value -> {:ok, value}
        end

      :undefined ->
        lookup_soft(fallback, env)
    end
  end

  defp lookup_soft({:gref, name, _marked}, env), do: Env.fetch_global(env, name)

  defp rec_value!(@rec_uninitialised, name), do: raise(Error, reason: {:rec_uninitialised, name})
  defp rec_value!(value, _name), do: value

  defp frame_at([frame | _], 0), do: frame
  defp frame_at([_ | rest], depth), do: frame_at(rest, depth - 1)

  defp drop_frames(lex, 0), do: lex
  defp drop_frames([_ | rest], depth), do: drop_frames(rest, depth - 1)

  # ---------------------------------------------------------------------------
  # define-values — top-level
  # ---------------------------------------------------------------------------
  #
  # The internal-definition position is desugared into a `letrec*`
  # multi-binding by the analyser; this clause only fires for a
  # `define-values` written at the top level (or inside a top-level
  # `begin` that the expander has already flattened). The producer is
  # evaluated once, normalised to a list of values, and each formal
  # name is installed as a top-level binding.

  defp eval_define_values(spec, expr, env) do
    values = values_to_list(expr.(env))

    spec
    |> bind_params(values, "define-values")
    |> Enum.each(fn {name, value} -> Env.define(env, name, value) end)

    :unspecified
  end

  # Multi-value returns reach this entry as `{:values, vs}`; bare
  # values are treated as a one-element value list. Mirrors the
  # producer-side coercion `call-with-values` performs.
  defp values_to_list({:values, vs}) when is_list(vs), do: vs
  defp values_to_list(v), do: [v]

  # ---------------------------------------------------------------------------
  # application
  # ---------------------------------------------------------------------------

  # Argument evaluation for applications with more arguments than the
  # specialised clauses cover. Body-recursive so the result comes out
  # in source order without a trailing `Enum.reverse/1`; it is never in
  # tail position (`apply_proc/2` follows it), so this costs no TCO. An
  # improper argument list was turned into a trailing `{:raise, _}`
  # node by the analyser.
  defp eval_args([], _env), do: []

  defp eval_args([h | t], env) do
    v = single_value!(h.(env))
    [v | eval_args(t, env)]
  end

  # A closure's body is `{names, code}`, where `code` is the compiled
  # body; application pushes the positional frame
  # `{names, arg1, arg2, ...}` that the analyser resolved the body's
  # references against, then tail-calls `code`. For the common
  # fixed-arity case the frame is a single `List.to_tuple/1`, with the
  # arity check done on the resulting tuple size.
  @spec apply_proc(Value.t(), [Value.t()]) :: eval_result()
  def apply_proc({:closure, {:fixed, n, _}, {names, body}, %Env{lex: lex} = env, name}, args) do
    frame = List.to_tuple([names | args])

    if tuple_size(frame) == n + 1 do
      body.(%{env | lex: [frame | lex]})
    else
      raise Error, reason: {:arity_mismatch, name, {:exact, n}, length(args)}
    end
  end

  def apply_proc({:closure, params, {names, body}, env, name}, args) do
    values = params |> bind_params(args, name) |> Enum.map(&elem(&1, 1))
    body.(Env.push_frame(env, List.to_tuple([names | values])))
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

  # `letrec*` backs both user-facing recursive bindings (the `letrec`
  # and named-`let` bootstrap macros expand to it) and internal-define
  # splicing (see `Schooner.Eval.Analyze`). Init expressions are
  # evaluated left-to-right in a frame whose closure values reference
  # the frame's identity — `Env.extend_rec/2` plus `Env.rec_put/3` ties
  # the knot without any after-the-fact mutation of the closures
  # themselves.
  #
  # On normal body return, `finalize_letrec_star/3` walks the result
  # value: if any closure's env still names the rec frame's
  # process-dictionary slot, the slot is *kept alive* with its now-
  # finalised snapshot so escaped closures (and any inner closures
  # they reach via rec lookups, including mutually-recursive
  # bindings) can resolve their rec names through it. If no closure
  # in the result references the slot, it is released as usual. A kept
  # slot is immutable after letrec exit: the evaluator never writes to
  # it again.
  defp eval_letrec_star(names, bindings, body, env) do
    rec_env = Env.extend_rec(env, names)
    [{:rec, ref} | _] = rec_env.lex

    result =
      try do
        Enum.each(bindings, &init_binding(&1, rec_env))
        body.(rec_env)
      rescue
        e ->
          Env.release_rec(rec_env)
          reraise(e, __STACKTRACE__)
      end

    finalize_letrec_star(result, ref, rec_env)
  end

  defp finalize_letrec_star(result, ref, rec_env) do
    if escapes_rec?(result, ref) do
      result
    else
      Env.release_rec(rec_env)
      result
    end
  end

  defp init_binding({:single, slot, init}, rec_env) do
    Env.rec_put(rec_env, slot, single_value!(init.(rec_env)))
  end

  defp init_binding({:multi, spec, init, slots}, rec_env) do
    values = values_to_list(init.(rec_env))

    spec
    |> bind_params(values, "define-values")
    |> Enum.zip(slots)
    |> Enum.each(fn {{_name, value}, slot} -> Env.rec_put(rec_env, slot, value) end)
  end

  # Quasiquote templates compile to closures that rebuild only the
  # non-constant spine. The head is evaluated before the tail, keeping
  # unquoted expressions in left-to-right order.
  defp compile_template({:qc, datum}, _g), do: fn _env -> datum end
  defp compile_template({:qu, expr}, g), do: compile(expr, g)

  defp compile_template({:qcons, head, tail}, g) do
    head = compile_template(head, g)
    tail = compile_template(tail, g)

    fn env ->
      h = head.(env)
      [h | tail.(env)]
    end
  end

  defp compile_template({:qsplice, expr, tail}, g) do
    expr = compile(expr, g)
    tail = compile_template(tail, g)

    fn env ->
      spliced = expr.(env)
      rest = tail.(env)
      splice_append(spliced, rest, "unquote-splicing")
    end
  end

  defp compile_template({:qvec, template}, g) do
    template = compile_template(template, g)
    fn env -> Value.vector(scheme_list_to_elixir(template.(env))) end
  end

  defp splice_append([], rest, _ctx), do: rest

  defp splice_append([h | t], rest, ctx) do
    [h | splice_append(t, rest, ctx)]
  end

  defp splice_append(_, _, ctx), do: raise(Error, reason: {:bad_special_form, ctx})

  defp scheme_list_to_elixir([]), do: []
  defp scheme_list_to_elixir([h | t]), do: [h | scheme_list_to_elixir(t)]

  # ---------------------------------------------------------------------------
  # letrec* slot escape detection
  # ---------------------------------------------------------------------------

  # Walk `value` returning true iff any closure in the tree references
  # `{:rec, ref}` in its captured env. The walk recurses into every
  # aggregate value tag that can carry a closure — pairs, vectors,
  # records, multi-values, promises, parameters, error objects — and
  # returns false for atomic and opaque tags. A missed aggregate
  # tag would prematurely release a slot a captured closure still
  # depends on, surfacing as a delayed lookup failure, so extending
  # the value model means extending this walk.
  #
  # Detection of `{:rec, ref}` in a closure's env directly is
  # sufficient: every closure constructed during the body's
  # evaluation captures the rec frame in its env at construction
  # time, so any closure that depends on the slot has the rec marker
  # somewhere in its lex chain. Closures captured *before* the
  # letrec entered have envs that don't name this ref — even if they
  # later end up in the result tree by reference, they don't depend
  # on the slot.
  @spec escapes_rec?(Value.t() | {:values, [Value.t()]}, reference()) :: boolean()
  defp escapes_rec?({:closure, _params, _body, %Env{lex: lex}, _name}, ref) do
    lex_has_rec?(lex, ref)
  end

  defp escapes_rec?([h | t], ref), do: escapes_rec?(h, ref) or escapes_rec?(t, ref)

  defp escapes_rec?({:vector, tup}, ref), do: tuple_has_escape?(tup, ref)
  defp escapes_rec?({:record, _type_id, fields}, ref), do: tuple_has_escape?(fields, ref)

  defp escapes_rec?({:values, vs}, ref) when is_list(vs) do
    Enum.any?(vs, &escapes_rec?(&1, ref))
  end

  defp escapes_rec?({:promise, _kind, v}, ref), do: escapes_rec?(v, ref)

  defp escapes_rec?({:parameter, _id, init, conv}, ref) do
    escapes_rec?(init, ref) or escapes_rec?(conv, ref)
  end

  defp escapes_rec?({:error_obj, _kind, msg, irritants}, ref) do
    escapes_rec?(msg, ref) or Enum.any?(irritants, &escapes_rec?(&1, ref))
  end

  defp escapes_rec?(_other, _ref), do: false

  defp lex_has_rec?([], _ref), do: false
  defp lex_has_rec?([{:rec, this_ref} | _rest], ref) when this_ref === ref, do: true
  defp lex_has_rec?([_frame | rest], ref), do: lex_has_rec?(rest, ref)

  defp tuple_has_escape?(tup, ref) do
    Enum.any?(0..(tuple_size(tup) - 1)//1, &escapes_rec?(elem(tup, &1), ref))
  end

  # ---------------------------------------------------------------------------
  # guard
  # ---------------------------------------------------------------------------

  # `guard` is a core form rather than a `syntax-rules` macro because
  # it has to escape the body once a clause matches; it was written
  # before `call/cc` existed and escapes with Elixir `throw` / `catch`
  # directly. The handler is wrapped as a `:primitive` so
  # `apply_proc/2` invokes it with the same machinery as a user
  # handler — `with-exception-handler` and `guard` are
  # indistinguishable from the raise side.
  defp eval_guard(names, clauses, body, env) do
    tag = make_ref()
    handler = build_guard_handler(tag)
    # Snapshot/restore the whole stack rather than `pop`ing once in
    # the after-clause: by the time we exit (matched-and-thrown,
    # re-raised, or normal-return) the handler may already have been
    # popped by `ExceptionState.raise_value/1`, and a blind pop
    # would discard an outer handler we didn't install.
    prev = ExceptionState.snapshot()
    ExceptionState.push(handler)

    try do
      body.(env)
    catch
      # R7RS §6.11: cond clauses run in the guard form's dynamic
      # extent, so the handler only escapes back here with the raw
      # raised value; the clauses are evaluated *after* control has
      # unwound past any parameterize/handler frames between the raise
      # site and this guard.
      :throw, {:schooner_guard, ^tag, raised} ->
        handler_env = Env.push_frame(env, {names, raised})

        case eval_guard_clauses(clauses, handler_env) do
          {:matched, value} -> value
          :no_match -> ExceptionState.raise_value(raised)
        end
    after
      ExceptionState.restore(prev)
    end
  end

  defp build_guard_handler(tag) do
    Value.primitive("%guard-handler", 1, fn [raised] ->
      throw({:schooner_guard, tag, raised})
    end)
  end

  defp compile_guard_clause({:else, body}, g), do: {:else, compile_body(body, g)}
  defp compile_guard_clause({:bad, _} = bad, _g), do: bad
  defp compile_guard_clause({:test, test}, g), do: {:test, compile(test, g)}

  defp compile_guard_clause({:arrow, test, proc_expr}, g),
    do: {:arrow, compile(test, g), compile(proc_expr, g)}

  defp compile_guard_clause({:test_body, test, body}, g),
    do: {:test_body, compile(test, g), compile_body(body, g)}

  defp eval_guard_clauses([], _env), do: :no_match
  defp eval_guard_clauses([{:else, body} | _rest], env), do: {:matched, body.(env)}
  defp eval_guard_clauses([{:bad, exception} | _rest], _env), do: raise(exception)

  defp eval_guard_clauses([clause | rest], env) do
    case eval_guard_clause(clause, env) do
      :no_match -> eval_guard_clauses(rest, env)
      {:matched, _} = m -> m
    end
  end

  defp eval_guard_clause({:test, test}, env) do
    case test.(env) do
      false -> :no_match
      val -> {:matched, val}
    end
  end

  defp eval_guard_clause({:arrow, test, proc_expr}, env) do
    case test.(env) do
      false ->
        :no_match

      val ->
        proc = proc_expr.(env)
        {:matched, apply_proc(proc, [val])}
    end
  end

  defp eval_guard_clause({:test_body, test, body}, env) do
    case test.(env) do
      false -> :no_match
      _ -> {:matched, body.(env)}
    end
  end
end
