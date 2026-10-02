defmodule Schooner.Eval do
  @moduledoc """
  Tail-recursive direct evaluator for the core Scheme language.

  `eval/2` takes a core form as produced by `Schooner.Expander` and
  runs it through `Schooner.Eval.Analyze`, which rewrites the
  s-expression into a tagged IR with every variable reference
  resolved. `compile/1` then turns that IR into a tree of Elixir
  closures — one `fn env -> ... end` per node, built once — so
  executing a program is a chain of closure calls with no per-node
  dispatch. `Schooner.compile/2` stores the analysed IR (plain data,
  safe to cache or persist) and `run_compiled/2` compiles it to
  closures on each run.

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
  def eval(form, %Env{lex: []} = env), do: compile(Analyze.analyze(form)).(env)

  @doc """
  Compile and evaluate an IR node produced by
  `Schooner.Eval.Analyze.analyze/1`.
  """
  @spec exec(Analyze.ir(), Env.t()) :: eval_result()
  def exec(ir, env), do: compile(ir).(env)

  @doc """
  Compile an IR node into a closure that evaluates it against an env.
  Child nodes are compiled up front, so the returned closure does no
  further dispatch on the IR.
  """
  @spec compile(Analyze.ir()) :: code()
  def compile({:const, value}), do: fn _env -> value end

  # The two shallowest depths cover almost every reference, so match
  # the frame directly instead of walking the chain.
  def compile({:lref, 0, index}), do: fn %Env{lex: [frame | _]} -> elem(frame, index) end
  def compile({:lref, 1, index}), do: fn %Env{lex: [_, frame | _]} -> elem(frame, index) end

  def compile({:lref, depth, index}),
    do: fn %Env{lex: lex} -> elem(frame_at(lex, depth), index) end

  def compile({:rref, depth, slot, name, fallback}) do
    fallback = compile(fallback)

    fn %Env{lex: lex} = env ->
      {:rec, ref} = frame_at(lex, depth)

      case :erlang.get(ref) do
        {:rec_frame, _names, values} -> rec_value!(elem(values, slot), name)
        :undefined -> fallback.(env)
      end
    end
  end

  def compile({:gref, name, marked}) do
    fn %Env{globals: globals} = env ->
      case :maps.find(name, :erlang.get(globals)) do
        {:ok, value} -> value
        :error -> resolve_marked_var(marked, name, env)
      end
    end
  end

  def compile({:if, test, then_e, else_e}) do
    test = compile(test)
    then_c = compile(then_e)
    else_c = compile(else_e)

    fn env ->
      case single_value!(test.(env)) do
        false -> else_c.(env)
        _ -> then_c.(env)
      end
    end
  end

  # A two-argument call through a global named like one of the inlined
  # arithmetic or comparison primitives. The head is still looked up
  # on every call, so a redefinition or shadowing is honoured; the
  # integer operation runs inline only when the looked-up procedure is
  # the standard one. A marked (macro-introduced) name is matched on
  # its base name, since that is what it falls back to.
  def compile({:app, {:gref, name, marked} = head, [a, b]} = node) do
    op = inline_name(name, marked)

    case Map.fetch(Base.inlined(), op) do
      {:ok, fun} -> compile_inline(op, fun, compile(head), a, b)
      :error -> compile_app(node)
    end
  end

  def compile({:app, _head, _args} = node), do: compile_app(node)

  def compile({:lambda, params, {names, body}, name}) do
    body = compile_body(body)
    fn env -> Value.closure(params, {names, body}, env, name) end
  end

  def compile({:define, name, expr}) do
    expr = compile(expr)

    fn env ->
      Env.define(env, name, single_value!(expr.(env)))
      :unspecified
    end
  end

  def compile({:define_values, spec, expr}) do
    expr = compile(expr)
    fn env -> eval_define_values(spec, expr, env) end
  end

  def compile({:seq, body}), do: compile_body(body)

  def compile({:letrec, names, bindings, body}) do
    bindings = Enum.map(bindings, &compile_binding/1)
    body = compile_body(body)
    fn env -> eval_letrec_star(names, bindings, body, env) end
  end

  # A `letrec*` whose lambdas are only ever called directly (see
  # `Schooner.Eval.Analyze`) never materialises them as closures. Its
  # frame is `{{}, body_0, body_1, ...}`: an empty names tuple, so
  # by-name lookup passes over it, followed by each lambda's compiled
  # body. The frame is built once, here.
  def compile({:fixrec, lambdas, body}) do
    frame = List.to_tuple([{} | Enum.map(lambdas, fn {_names, b} -> compile_body(b) end)])
    body = compile_body(body)
    fn %Env{lex: lex} = env -> body.(%{env | lex: [frame | lex]}) end
  end

  # A direct call to lambda `slot` of the `:fixrec` frame `depth`
  # levels up. The callee's frame goes on top of the `:fixrec` frame,
  # exactly where `apply_proc/2` would have put it on top of the
  # closure's env, and the compiled body is tail-called.
  def compile({:known_call, depth, slot, names, args}) do
    index = slot + 1

    case Enum.map(args, &compile/1) do
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

  def compile({:quasi, template}), do: compile_template(template)

  def compile({:guard, names, clauses, body}) do
    clauses = Enum.map(clauses, &compile_guard_clause/1)
    body = compile_body(body)
    fn env -> eval_guard(names, clauses, body, env) end
  end

  def compile({:raise, exception}), do: fn _env -> raise(exception) end

  defp inline_name(name, {:gref, base, nil}) do
    if Map.has_key?(Base.inlined(), name), do: name, else: base
  end

  defp inline_name(name, _marked), do: name

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
    defp compile_inline(unquote(name), fun, head, a, b) do
      a = compile(a)
      b = compile(b)

      fn env ->
        proc = single_value!(head.(env))
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
  # arguments left to right, as before.
  defp compile_app({:app, head, args}) do
    head = compile(head)

    case Enum.map(args, &compile/1) do
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
  defp compile_body([]), do: fn _env -> :unspecified end
  defp compile_body([last]), do: compile(last)

  defp compile_body([head | rest]) do
    head = compile(head)
    rest = compile_body(rest)

    fn env ->
      _ = head.(env)
      rest.(env)
    end
  end

  defp compile_binding({:single, slot, init}), do: {:single, slot, compile(init)}

  defp compile_binding({:multi, spec, init, slots}),
    do: {:multi, spec, compile(init), slots}

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

  # `letrec*` is the workhorse for both user-facing recursive bindings
  # (the `let`, `let*`, `letrec`, `letrec*`, named-`let` bootstrap
  # macros all expand to it eventually) and for internal-define
  # splicing (see `Schooner.Eval.Analyze`). Init expressions are evaluated
  # left-to-right in a frame whose closure values reference the
  # frame's identity — `Env.extend_rec/2` plus `rec_set/3` ties the
  # knot without any after-the-fact mutation of the closures
  # themselves.
  #
  # On normal body return, `finalize_letrec_star/3` walks the result
  # value: if any closure's env still names the rec frame's
  # process-dictionary slot, the slot is *kept alive* with its now-
  # finalised snapshot so escaped closures (and any inner closures
  # they reach via rec lookups, including mutually-recursive
  # bindings) can resolve their rec names through it. If no closure
  # in the result references the slot, it is released as usual. The
  # slot becomes immutable after letrec exit — the evaluator never
  # writes to a freed-but-kept slot.
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
  # non-constant spine. Head before tail, matching the old
  # left-to-right evaluation order.
  defp compile_template({:qc, datum}), do: fn _env -> datum end
  defp compile_template({:qu, expr}), do: compile(expr)

  defp compile_template({:qcons, head, tail}) do
    head = compile_template(head)
    tail = compile_template(tail)

    fn env ->
      h = head.(env)
      [h | tail.(env)]
    end
  end

  defp compile_template({:qsplice, expr, tail}) do
    expr = compile(expr)
    tail = compile_template(tail)

    fn env ->
      spliced = expr.(env)
      rest = tail.(env)
      splice_append(spliced, rest, "unquote-splicing")
    end
  end

  defp compile_template({:qvec, template}) do
    template = compile_template(template)
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
  # is identity-false for atomic / opaque tags. A missed aggregate
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
  # it has to escape the body once a clause matches, and the only
  # tools available pre-`call/cc` (phase 12) are Elixir `throw` /
  # `catch`. The handler is wrapped as a `:primitive` so
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

  defp compile_guard_clause({:else, body}), do: {:else, compile_body(body)}
  defp compile_guard_clause({:bad, _} = bad), do: bad
  defp compile_guard_clause({:test, test}), do: {:test, compile(test)}

  defp compile_guard_clause({:arrow, test, proc_expr}),
    do: {:arrow, compile(test), compile(proc_expr)}

  defp compile_guard_clause({:test_body, test, body}),
    do: {:test_body, compile(test), compile_body(body)}

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
