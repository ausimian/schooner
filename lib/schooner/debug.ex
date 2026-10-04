defmodule Schooner.Debug do
  @moduledoc """
  The opt-in `(schooner debug)` library: tracing, printing and
  assertions for script authors.

  `display`, `write` and `newline` return their rendered text rather
  than writing it to a port (see [Deviations](deviations.md)), so a
  `(display x)` dropped into a procedure body shows nothing. This
  library sends output to a *sink* the embedder chooses instead. Like
  `Schooner.Time`, it is not in the standard registry: a script can
  only import it from an environment built with it, so the default
  sandbox stays free of side effects.

      env =
        Schooner.Environment.new(
          pre_imports: [["scheme", "base"]],
          libraries: [Schooner.Debug.library(sink: {:logger, :debug})]
        )

      Schooner.eval!(~s|(import (schooner debug)) (trace "sum" (+ 1 2))|, env)
      # logs "sum: 3" and returns 3

  ## Syntax

  All three exports are syntax, not procedures, so each one knows
  where it was used:

    * `(trace label expr)` evaluates `expr`, sends
      `"<label>: <value>"` to the sink and returns the value unchanged.
      The label is rendered as by `display` and the value as by
      `write`; multiple values are written space-separated. Wrap any
      expression in place without restructuring the code around it.
      `trace` has to see the value, so `expr` is not in tail position,
      but tail calls within `expr` still are: wrapping a call to a
      long-running loop does not make the loop grow the stack.

    * `(print obj ...)` sends the `display` rendering of its arguments,
      separated by spaces, to the sink. Its value is unspecified.

    * `(assert expr)` and `(assert expr message)` return the value of
      `expr` when it is true. When it is `#f` they raise an error
      object, as `(error ...)` does, whose message is
      `"assertion failed: <expr>"` with the source text of `expr`,
      followed by `": <message>"` when a message is given. `message`
      is only evaluated when the assertion fails. A `guard` catches
      the error like any other; if nothing does, it reaches the host
      as a `Schooner.Error`.

  Because they are syntax, the names cannot be passed around as
  values: write `(lambda (x) (print x))` rather than `print`.

  ## Sinks

  `library/1` takes a required `:sink`:

    * `{:logger, level}` logs each message through `Logger` at
      `level`, with the script location in the `:schooner_location`
      metadata and the kind of message (`:trace` or `:print`) in
      `:schooner_debug`.
    * a pid is sent `{:schooner_debug, kind, text, location}`.
    * a 1-arity function is called with
      `%{kind: kind, text: text, location: location}`; its return
      value is ignored.

  `location` is the `Schooner.Location` of the `trace` or `print`
  form. Like the locations of errors, it is only recorded when the
  script is evaluated with `:file`, `locations: true` or
  `debug: true`; otherwise it is `nil`. The same holds for the
  location of a failed assertion.

  The sink runs in the evaluating process. If it raises, exits or
  throws, evaluation stops with a `Schooner.Primitive.Error`, which
  `Schooner.eval/3` returns as `{:error, exception}`. A script's
  `guard` does not catch it.

  ## Compiled scripts

  `Schooner.compile/3` expands macros when it compiles, so a compiled
  script keeps the sink of the environment it was compiled against.
  Compile against an environment with the sink you want to run with.
  """

  alias Schooner.Eval
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Expander.Positions, as: Pos
  alias Schooner.Expander.SyntaxRules
  alias Schooner.Library
  alias Schooner.Location
  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  require Logger

  @typedoc "Where `trace` and `print` send their output."
  @type sink :: {:logger, Logger.level()} | pid() | (message() -> any())

  @typedoc "What a function sink is called with."
  @type message :: %{kind: :trace | :print, text: binary(), location: Location.t() | nil}

  @doc """
  Build the `(schooner debug)` library. Pass it to
  `Schooner.Environment.new/1` in `:libraries` to let scripts evaluated
  against the environment `(import (schooner debug))`.

  ## Options

    * `:sink` (required) — where `trace` and `print` send their output:
      `{:logger, level}`, a pid, or a 1-arity function. See "Sinks"
      above.
  """
  @spec library(keyword()) :: Library.t()
  def library(opts) when is_list(opts) do
    sink =
      case Keyword.fetch(opts, :sink) do
        {:ok, sink} -> validate_sink!(sink)
        :error -> raise ArgumentError, "Schooner.Debug.library/1 requires a :sink option"
      end

    Library.new(
      name: ["schooner", "debug"],
      exports: %{
        "trace" => {:macro, trace_macro(sink)},
        "print" => {:macro, print_macro(sink)},
        "assert" => {:macro, assert_macro()}
      }
    )
  end

  defp validate_sink!({:logger, level} = sink) do
    if level in Logger.levels() do
      sink
    else
      raise ArgumentError,
            "Schooner.Debug sink {:logger, level} needs a Logger level, got #{inspect(level)}"
    end
  end

  defp validate_sink!(pid) when is_pid(pid), do: pid
  defp validate_sink!(fun) when is_function(fun, 1), do: fun

  defp validate_sink!(other) do
    raise ArgumentError,
          "Schooner.Debug :sink must be {:logger, level}, a pid or a 1-arity function, " <>
            "got #{inspect(other)}"
  end

  # ---------------------------------------------------------------------------
  # Transformers
  #
  # Each macro expands to a call of a procedure that is not exported,
  # quoted into the expansion as a constant so it is reached however the
  # script imported or renamed the macro, and whatever it has bound
  # locally. The call's first argument is `Eval.call_site/0`, which
  # compilation replaces with the location of the macro use: the
  # expansion takes that position, and the forms the user wrote keep
  # their own.
  # ---------------------------------------------------------------------------

  defp trace_macro(sink) do
    proc =
      Value.primitive("trace", 3, fn [loc, label, thunk] -> trace(sink, loc, label, thunk) end)

    fn
      [_trace, label, expr], t ->
        located_call(proc, [{label, Pos.nth(t, 1)}, thunk(expr, Pos.nth(t, 2), t)], t)

      _form, _t ->
        raise EvalError, reason: {:bad_special_form, "trace"}
    end
  end

  defp print_macro(sink) do
    proc = Value.primitive("print", {:at_least, 1}, fn [loc | objs] -> print(sink, loc, objs) end)

    fn [_print | objs], t ->
      if proper_list?(objs) do
        located_call(proc, user_forms(objs, Pos.cdr(t)), t)
      else
        raise EvalError, reason: {:bad_special_form, "print"}
      end
    end
  end

  defp assert_macro do
    proc = Value.primitive("assert", {:between, 3, 4}, &assert/1)

    fn
      [_assert, expr], t ->
        located_call(proc, [source_text(expr, t), {expr, Pos.nth(t, 1)}], t)

      [_assert, expr, message], t ->
        args = [source_text(expr, t), {expr, Pos.nth(t, 1)}, thunk(message, Pos.nth(t, 2), t)]
        located_call(proc, args, t)

      _form, _t ->
        raise EvalError, reason: {:bad_special_form, "assert"}
    end
  end

  # `((quote proc) (quote <call site>) arg ...)`, where each of `args`
  # is a `{form, tree}` pair.
  defp located_call(proc, args, t) do
    head = [quote_form(proc, t), quote_form(Eval.call_site(), t)]
    {forms, trees} = Enum.unzip(head ++ args)
    {forms, Pos.list(trees, nil, t)}
  end

  defp quote_form(datum, t) do
    form = [{:sym, "quote"}, datum]
    {form, Pos.fresh(form, t)}
  end

  # `(lambda () form)`, keeping `form`'s tree `ft`.
  defp thunk(form, ft, t) do
    {[{:sym, "lambda"}, [], form],
     Pos.list([Pos.fresh({:sym, "lambda"}, t), Pos.fresh([], t), ft], nil, t)}
  end

  # `(quote expr)` as the user wrote it: an `assert` in a macro template
  # sees the template's identifiers with their hygiene marks.
  defp source_text(expr, t), do: quote_form(unmark(expr), t)

  defp unmark({:sym, name} = sym) do
    case SyntaxRules.strip_mark(name) do
      {:ok, base} -> {:sym, base}
      :error -> sym
    end
  end

  defp unmark([h | t]), do: [unmark(h) | unmark(t)]

  defp unmark({:vector, items}),
    do: {:vector, items |> Tuple.to_list() |> Enum.map(&unmark/1) |> List.to_tuple()}

  defp unmark(other), do: other

  # Pair each of `forms` with its tree in the spine `t`.
  defp user_forms([], _t), do: []
  defp user_forms([form | rest], t), do: [{form, Pos.car(t)} | user_forms(rest, Pos.cdr(t))]

  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_), do: false

  # ---------------------------------------------------------------------------
  # Procedures
  # ---------------------------------------------------------------------------

  defp trace(sink, loc, label, thunk) do
    result = Eval.apply_proc(thunk, [])
    emit(sink, :trace, loc, [Value.display(label), ?: | written(result)])
    result
  end

  defp written({:values, vs}), do: Enum.map(vs, &[?\s | Value.write(&1)])
  defp written(v), do: [?\s | Value.write(v)]

  defp print(sink, loc, objs) do
    emit(sink, :print, loc, Enum.map_intersperse(objs, ?\s, &Value.display/1))
    :unspecified
  end

  defp assert([_loc, _datum, value | _message]) when value !== false, do: value

  defp assert([loc, datum, false | message]) do
    text = "assertion failed: " <> Value.write(datum)

    text =
      case message do
        [] -> text
        [thunk] -> text <> ": " <> Value.display(Eval.single_value!(Eval.apply_proc(thunk, [])))
      end

    Eval.raise_located(Value.error_object(:user, Value.string(text), []), loc)
  end

  defp emit(sink, kind, loc, iodata) do
    deliver(sink, kind, IO.iodata_to_binary(iodata), loc)
  catch
    class, reason ->
      banner = Exception.format_banner(class, reason, __STACKTRACE__)
      raise PError, reason: {:debug_sink, Atom.to_string(kind), banner}, location: loc
  end

  defp deliver({:logger, level}, kind, text, loc) do
    # The embedder chooses which metadata its Logger formats.
    # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
    Logger.log(level, text, schooner_debug: kind, schooner_location: loc)
  end

  defp deliver(pid, kind, text, loc) when is_pid(pid),
    do: send(pid, {:schooner_debug, kind, text, loc})

  defp deliver(fun, kind, text, loc), do: fun.(%{kind: kind, text: text, location: loc})
end
