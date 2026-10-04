defmodule Schooner.BacktraceTest do
  use ExUnit.Case, async: true

  alias Schooner.Environment
  alias Schooner.Eval.BacktraceState
  alias Schooner.Frame
  alias Schooner.Library
  alias Schooner.Library.Loader
  alias Schooner.Location

  @guide_path "guides/tooling.md"
  @external_resource @guide_path
  @guide File.read!(@guide_path)

  defp env, do: Environment.new(pre_imports: [["scheme", "base"]])

  defp error!(source, opts \\ []) do
    assert {:error, e} = Schooner.eval(source, env(), [file: "t.scm", debug: true] ++ opts)
    e
  end

  # Frames as `{name, line, column, tail?}`, most recent first.
  defp frames(e) do
    for %Frame{name: name, location: loc, tail?: tail?} <- e.scheme_backtrace do
      {name, loc && loc.line, loc && loc.column, tail?}
    end
  end

  defp names(e), do: Enum.map(e.scheme_backtrace, & &1.name)

  describe "call chains" do
    test "a three-deep non-tail chain ending in a primitive error lists each call" do
      e =
        error!("""
        (define (a) (+ 1 (b)))
        (define (b) (+ 1 (c)))
        (define (c) (+ 1 (car '())))
        (a)
        """)

      assert %Schooner.Primitive.Error{} = e

      assert frames(e) == [
               {"car", 3, 18, false},
               {"c", 2, 18, false},
               {"b", 1, 18, false},
               {"a", 4, 1, false}
             ]
    end

    test "calls that have returned are dropped" do
      e =
        error!("""
        (define (helper x) (* x 2))
        (define (f x)
          (helper x)
          (helper x)
          (vector-ref (vector) x))
        (f 1)
        """)

      assert frames(e) == [{"vector-ref", 5, 3, true}, {"f", 6, 1, false}]
    end

    test "tail calls are kept and marked, in order" do
      e =
        error!("""
        (define (f) (g))
        (define (g) (h))
        (define (h) (car 1))
        (f)
        """)

      assert frames(e) == [
               {"car", 3, 13, true},
               {"h", 2, 13, true},
               {"g", 1, 13, true},
               {"f", 4, 1, false}
             ]
    end

    test "an anonymous procedure is named <lambda>" do
      e = error!("((lambda (x) (car x)) 1)")
      assert names(e) == ["car", "<lambda>"]
    end

    test "an arity mismatch records the call that failed" do
      e = error!("(define (f x) x)\n(define (g) (f))\n(g)")
      assert %Schooner.Eval.Error{reason: {:arity_mismatch, "f", _, 0}} = e
      assert frames(e) == [{"f", 2, 13, true}, {"g", 3, 1, false}]
    end

    test "a parameter call is recorded" do
      e = error!("(define p (make-parameter 1))\n(define (f) (p 2))\n(f)")
      assert frames(e) == [{"<parameter>", 2, 13, true}, {"f", 3, 1, false}]
    end

    test "an uncaught raise carries the calls that led to it" do
      e = error!("(define (f) (raise 'boom))\n(f)")
      assert %Schooner.Error{} = e
      assert names(e) == ["raise", "f"]
    end

    test "a host type error carries the calls that led to it" do
      lib =
        Schooner.Host.library(
          name: ["host"],
          primitives: [
            {"host-len", 1,
             fn [s] -> String.length(Schooner.Host.to_string!(s, op: "host-len")) end}
          ]
        )

      environment = Environment.new(pre_imports: [["scheme", "base"], ["host"]], libraries: [lib])

      e =
        assert_raise Schooner.Host.TypeError, fn ->
          Schooner.eval!("(define (f x) (host-len x))\n(f 1)", environment,
            file: "t.scm",
            debug: true
          )
        end

      assert names(e) == ["host-len", "f"]
    end
  end

  describe "direct and inlined calls" do
    test "a named let loop compiled to direct calls records each iteration" do
      e = error!("(let loop ((i 0))\n  (if (= i 3) (car i) (loop (+ i 1))))")

      assert frames(e) == [
               {"car", 2, 15, true},
               {"loop", 2, 23, true},
               {"loop", 2, 23, true},
               {"loop", 2, 23, true},
               {"loop", 1, 1, false}
             ]
    end

    test "direct calls between letrec lambdas are recorded" do
      e =
        error!("""
        (define (run)
          (letrec ((ping (lambda (n) (if (= n 0) (car n) (pong (- n 1)))))
                   (pong (lambda (n) (ping n))))
            (+ 1 (ping 2))))
        (run)
        """)

      assert names(e) == ["car", "ping", "pong", "ping", "pong", "ping", "run"]
      assert e.scheme_backtrace |> Enum.at(-2) |> Map.fetch!(:tail?) == false
    end

    test "inlined integer arithmetic is not recorded, but any other operands are" do
      e = error!("(define (f x) (+ 1 (* x 2) (car x)))\n(f 3)")
      assert names(e) == ["car", "f"]

      e = error!("(define (f x) (* x 2))\n(f \"a\")")
      assert frames(e) == [{"*", 1, 15, true}, {"f", 2, 1, false}]
    end

    test "a procedure a primitive calls has no frame, but its calls do" do
      e = error!("(define (f l) (map (lambda (x) (car x)) l))\n(f '((1) 2))")
      assert names(e) == ["car", "map", "f"]
    end
  end

  describe "escapes" do
    test "a continuation escape drops the frames of the abandoned extent" do
      e =
        error!("""
        (define (deep k) (+ 1 (deeper k)))
        (define (deeper k) (+ 1 (k 0)))
        (define (f)
          (call/cc (lambda (k) (deep k)))
          (car 1))
        (f)
        """)

      assert frames(e) == [{"car", 5, 3, true}, {"f", 6, 1, false}]
    end

    test "a continuation escape through apply drops the abandoned frames" do
      e =
        error!("""
        (define (deep k) (+ 1 (k 0)))
        (define (f)
          (call-with-values
            (lambda () (apply call/cc (list (lambda (k) (deep k)))))
            (lambda (x) (car x))))
        (f)
        """)

      # `apply` is the producer's own tail call; `deep` and the
      # continuation it invoked are gone.
      assert names(e) == ["car", "apply", "call-with-values", "f"]
    end

    test "a guard that handles a raise drops the frames of its body" do
      e =
        error!("""
        (define (thrower) (+ 1 (raise 'oops)))
        (define (f)
          (guard (e (#t (car e)))
            (thrower)))
        (f)
        """)

      assert frames(e) == [{"car", 3, 17, false}, {"f", 5, 1, false}]
    end

    test "a guard with no matching clause re-raises with the raise's history" do
      e =
        error!("""
        (define (thrower) (+ 1 (raise 'oops)))
        (define (f)
          (guard (e ((string? e) e))
            (thrower)))
        (f)
        """)

      assert %Schooner.Error{value: {:sym, "oops"}} = e
      assert names(e) == ["raise", "thrower", "f"]
    end

    test "a primitive that returns drops what its callbacks recorded" do
      # Each `map` callback tail-calls `with-exception-handler`, whose
      # handler tail-calls `wrap`; none of that is live once it returns.
      e =
        error!("""
        (define (wrap c) (list c))
        (define (handler c) (wrap c))
        (define (f l)
          (map (lambda (x)
                 (if (= x 3)
                     (car x)
                     (with-exception-handler handler (lambda () (raise-continuable x)))))
               l))
        (f '(1 2 3))
        """)

      assert names(e) == ["car", "map", "f"]
    end

    test "an after thunk that raises does not list the abandoned body's calls" do
      e =
        error!("""
        (define (cleanup) (cdr 1))
        (define (body) (car 1))
        (define (f) (dynamic-wind (lambda () #f) body (lambda () (cleanup))))
        (f)
        """)

      assert names(e) == ["cdr", "cleanup", "dynamic-wind", "f"]
    end

    test "a guard compiled without debug drops the frames of debug code it catches" do
      registry =
        Loader.load_string(
          """
          (define-library (handling)
            (export handle)
            (import (scheme base))
            (begin
              (define (handle thunk)
                (guard (e (#t (car e)))
                  (thunk)))))
          """,
          Library.standard()
        )

      environment =
        Environment.new(
          pre_imports: [["scheme", "base"], ["handling"]],
          libraries: [registry[["handling"]]]
        )

      assert {:error, e} =
               Schooner.eval("(define (go) (raise 2))\n(handle go)", environment,
                 file: "t.scm",
                 debug: true
               )

      assert names(e) == ["handle"]
    end

    test "a dynamic-wind after thunk leaves the history of the error alone" do
      e =
        error!("""
        (define (cleanup) (list 'done))
        (define (body) (car 1))
        (define (f) (dynamic-wind (lambda () #f) body (lambda () (cleanup))))
        (f)
        """)

      assert names(e) == ["car", "dynamic-wind", "f"]
    end
  end

  describe "bounds" do
    test "a 1M-iteration tail loop keeps at most :backtrace_depth frames" do
      src = """
      (define (loop n) (if (= n 0) (car n) (loop (- n 1))))
      (loop 1000000)
      """

      assert length(error!(src).scheme_backtrace) == BacktraceState.default_depth()
      assert length(error!(src, backtrace_depth: 5).scheme_backtrace) == 5
      assert length(error!(src, backtrace_depth: 1).scheme_backtrace) == 1
    end

    test "the history never holds more than :backtrace_depth entries" do
      parent = self()

      probe =
        Schooner.Host.library(
          name: ["probe"],
          primitives: [
            {"probe", 0,
             fn [] ->
               {_count, ring} = BacktraceState.snapshot()
               send(parent, {:ring_size, tuple_size(ring)})
               true
             end}
          ]
        )

      environment =
        Environment.new(pre_imports: [["scheme", "base"], ["probe"]], libraries: [probe])

      Schooner.eval!(
        "(define (loop n) (if (= n 0) (probe) (loop (- n 1))))\n(loop 100000)",
        environment,
        debug: true,
        backtrace_depth: 7
      )

      assert_received {:ring_size, 7}
    end

    test "a 1M-iteration tail loop under debug runs in constant memory" do
      parent = self()

      {pid, monitor} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{size: 1_000_000, kill: true, error_logger: false})

          result =
            Schooner.eval!(
              """
              (define (loop n acc)
                (if (= n 0) acc (loop (- n 1) (+ acc (car (list 1))))))
              (loop 1000000 0)
              """,
              env(),
              debug: true
            )

          send(parent, {:done, self(), result})
        end)

      assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 30_000
      assert reason == :normal
      assert_received {:done, ^pid, 1_000_000}
    end

    test "rejects a :backtrace_depth that is not a positive integer" do
      for bad <- [0, -1, :many, 2.0] do
        assert_raise ArgumentError, ~r/backtrace_depth/, fn ->
          Schooner.eval("1", env(), debug: true, backtrace_depth: bad)
        end
      end
    end
  end

  describe "per-evaluation state" do
    test "without debug no history is kept" do
      assert {:error, e} = Schooner.eval("(define (f) (car 1))\n(f)", env(), file: "t.scm")
      assert e.scheme_backtrace == nil
      assert BacktraceState.snapshot() == nil
    end

    test "the history is reset for each evaluation and restored afterwards" do
      _ = error!("(define (f) (car 1))\n(f)")
      assert BacktraceState.snapshot() == nil

      e = error!("(vector-ref (vector) 0)")
      assert names(e) == ["vector-ref"]
    end

    test "an earlier top-level form's calls are not reported" do
      e = error!("(define (f) 1)\n(f)\n(car 1)")
      assert names(e) == ["car"]
    end

    test "an error found before the script runs has an empty backtrace" do
      e = error!("(if)")
      assert e.scheme_backtrace == []
    end

    test "a debug closure called after its evaluation records nothing" do
      {:ok, f} = Schooner.eval("(lambda (x) (car x))", env(), debug: true)
      assert {:error, e} = Schooner.apply(f, [1])
      assert e.scheme_backtrace == nil
      assert BacktraceState.snapshot() == nil
    end
  end

  describe "run_compiled/3" do
    test "keeps the debug option given to compile" do
      compiled = Schooner.compile!("(define (f) (car 1))\n(f)", env(), file: "c.scm", debug: true)
      assert {:error, e} = Schooner.run_compiled(compiled, env())
      assert names(e) == ["car", "f"]
      assert hd(e.scheme_backtrace).location == %Location{file: "c.scm", line: 1, column: 13}
    end

    test "debug: true turns backtraces on for one run" do
      compiled = Schooner.compile!("(define (f) (car 1))\n(f)", env(), file: "c.scm")

      assert {:error, e} = Schooner.run_compiled(compiled, env())
      assert e.scheme_backtrace == nil

      assert {:error, e} = Schooner.run_compiled(compiled, env(), debug: true, backtrace_depth: 1)
      assert frames(e) == [{"car", 1, 13, true}]
    end

    test "debug: false turns them off" do
      compiled = Schooner.compile!("(car 1)", env(), file: "c.scm", debug: true)
      assert {:error, e} = Schooner.run_compiled(compiled, env(), debug: false)
      assert e.scheme_backtrace == nil
    end

    test "debug: true records calls in a program compiled without locations" do
      compiled =
        Schooner.compile!(
          "(define (f) (guard (e (#t => (lambda (x) (car x)))) (raise 1)))\n(f)",
          env()
        )

      assert {:error, e} = Schooner.run_compiled(compiled, env(), debug: true)
      assert names(e) == ["car", "<lambda>", "f"]
      assert Enum.all?(e.scheme_backtrace, &(&1.location == nil))
    end

    test "rejects unknown options" do
      compiled = Schooner.compile!("1", env())

      assert_raise ArgumentError, fn ->
        Schooner.run_compiled(compiled, env(), file: "x.scm")
      end
    end
  end

  describe "format_error/2" do
    test "lists frames after the message, marking tail calls" do
      e = error!("(define (f x)\n  (car x))\n(f 1)")

      assert Schooner.format_error(e) == """
             t.scm:2:3: type error in `car`: expected pair, got 1

             Scheme backtrace (most recent first):
               car  t.scm:2:3 (tail call)
               f    t.scm:3:1\
             """
    end

    test "renders a frame without a location" do
      e = %Schooner.Eval.Error{
        reason: :x,
        message: "boom",
        scheme_backtrace: [%Frame{name: "f", location: nil, tail?: false}]
      }

      assert Schooner.format_error(e) ==
               "boom\n\nScheme backtrace (most recent first):\n  f  (unknown location)"
    end

    test "omits an empty backtrace" do
      assert Schooner.format_error(error!("(if)")) == "t.scm:1:1: malformed `if` form"
    end
  end

  describe "guides/tooling.md" do
    defp pricing_env do
      Environment.new(
        standard_libraries: [:base, :char, :write],
        pre_imports: [["scheme", "base"]],
        libraries: [
          Schooner.Host.library(
            name: ["myapp", "catalog"],
            primitives: [{"unit-price", 1, fn [_sku] -> 10 end}]
          )
        ]
      )
    end

    defp section, do: hd(Regex.run(~r/## Backtraces\n.*?(?=\n## |\z)/s, @guide))

    test "the pricing example matches the guide" do
      [_, script] =
        Regex.run(~r/and one script, `scripts\/pricing.scm`:\n\n```scheme\n(.*?)```/s, @guide)

      [rendered | _] = for [_, text] <- Regex.scan(~r/```text\n(.*?)\n```/s, section()), do: text

      assert {:error, error} =
               Schooner.eval(script <> ~s|(order-total '(("widget" . "3")))|, pricing_env(),
                 file: "scripts/pricing.scm",
                 debug: true
               )

      assert Schooner.format_error(error) == rendered
    end

    test "the loop example matches the guide" do
      [_, script] = Regex.run(~r/Given `scripts\/sum.scm`:\n\n```scheme\n(.*?)```/s, section())
      [_, rendered] = for [_, text] <- Regex.scan(~r/```text\n(.*?)\n```/s, section()), do: text

      assert {:error, error} = Schooner.eval(script, env(), file: "scripts/sum.scm", debug: true)
      assert Schooner.format_error(error) == rendered
    end
  end
end
