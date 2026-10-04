defmodule Schooner.DebugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Schooner.Environment
  alias Schooner.Library
  alias Schooner.Library.NotFoundError
  alias Schooner.Location
  alias Schooner.Primitive.Error, as: PError

  defp env(sink \\ self()) do
    Environment.new(
      pre_imports: [["scheme", "base"]],
      libraries: [Schooner.Debug.library(sink: sink)]
    )
  end

  defp eval(source, opts \\ []),
    do: Schooner.eval("(import (schooner debug))\n" <> source, env(), opts)

  defp at(nil), do: nil
  defp at(%Location{file: file, line: line, column: column}), do: {file, line, column}

  # Collect every message the pid sink has sent so far.
  defp sent do
    receive do
      {:schooner_debug, kind, text, _loc} -> [{kind, text} | sent()]
    after
      0 -> []
    end
  end

  describe "library/1" do
    test "builds (schooner debug) exporting trace, print and assert as syntax" do
      lib = Schooner.Debug.library(sink: self())

      assert %Library{name: ["schooner", "debug"]} = lib
      assert lib.exports |> Map.keys() |> Enum.sort() == ["assert", "print", "trace"]
      assert Enum.all?(Map.values(lib.exports), &match?({:macro, _}, &1))
    end

    test "is not in the standard registry" do
      refute Map.has_key?(Library.standard(), ["schooner", "debug"])
      refute Map.has_key?(Environment.registry(Environment.new()), ["schooner", "debug"])
    end

    test "can't be imported unless the embedder passes it in" do
      assert {:error, %NotFoundError{name: ["schooner", "debug"]}} =
               Schooner.eval("(import (schooner debug)) 1", Environment.new())
    end

    test "requires a sink" do
      assert_raise ArgumentError, ~r/requires a :sink/, fn -> Schooner.Debug.library([]) end
    end

    test "rejects a sink it doesn't know" do
      assert_raise ArgumentError, ~r/:sink must be/, fn ->
        Schooner.Debug.library(sink: :stdout)
      end

      assert_raise ArgumentError, ~r/:sink must be/, fn ->
        Schooner.Debug.library(sink: fn _, _ -> :ok end)
      end

      assert_raise ArgumentError, ~r/needs a Logger level/, fn ->
        Schooner.Debug.library(sink: {:logger, :loud})
      end
    end
  end

  describe "trace" do
    test "sends label: value and returns the value" do
      assert {:ok, 30} = eval(~s|(trace "line-total" (* 10 3))|)
      assert sent() == [{:trace, "line-total: 30"}]
    end

    test "displays the label and writes the value" do
      assert {:ok, "hi"} = eval(~s|(trace 'greeting "hi")|)
      assert {:ok, _} = eval(~s|(trace "pair" (cons "a" #\\b))|)
      assert sent() == [{:trace, ~s|greeting: "hi"|}, {:trace, ~s|pair: ("a" . #\\b)|}]
    end

    test "passes multiple values through and writes them all" do
      assert {:ok, [1, 2]} =
               eval(~s|(call-with-values (lambda () (trace "mv" (values 1 2))) list)|)

      assert {:ok, []} = eval(~s|(call-with-values (lambda () (trace "none" (values))) list)|)
      assert sent() == [{:trace, "mv: 1 2"}, {:trace, "none:"}]
    end

    test "returns a procedure unchanged" do
      assert {:ok, 7} = eval(~s|((trace "add" (lambda (x) (+ x 1))) 6)|)
      assert [{:trace, "add: #<procedure" <> _}] = sent()
    end

    test "evaluates its expression once" do
      assert {:ok, 1} =
               eval(~s|(trace "x" (begin (print "evaluated") 1))|)

      assert sent() == [{:print, "evaluated"}, {:trace, "x: 1"}]
    end

    test "keeps its arguments' errors" do
      assert {:error, %PError{reason: {:type_error, "car", _, _}}} = eval(~s|(trace "x" (car 1))|)
      assert sent() == []
    end

    test "is located at the trace form" do
      assert {:ok, 3} = eval(~s|(define (f x)\n  (trace "f" (+ x 1)))\n(f 2)|, file: "t.scm")
      assert_received {:schooner_debug, :trace, "f: 3", loc}
      assert at(loc) == {"t.scm", 3, 3}
    end

    test "is placed at the user's form inside another macro" do
      source = ~s|(cond ((> 1 2) 'no)\n      (else (trace "c" 'yes)))|
      assert {:ok, _} = eval(source, file: "t.scm")
      assert_received {:schooner_debug, :trace, "c: yes", loc}
      assert at(loc) == {"t.scm", 3, 13}
    end

    test "has no location unless locations are on" do
      assert {:ok, 1} = eval(~s|(trace "x" 1)|)
      assert_received {:schooner_debug, :trace, "x: 1", nil}
    end

    test "is located with locations: true and with debug: true" do
      assert {:ok, 1} = eval(~s|(trace "x" 1)|, locations: true)
      assert_received {:schooner_debug, :trace, "x: 1", loc}
      assert at(loc) == {nil, 2, 1}

      assert {:ok, 1} = eval(~s|(trace "x" 1)|, debug: true, file: "t.scm")
      assert_received {:schooner_debug, :trace, "x: 1", loc}
      assert at(loc) == {"t.scm", 2, 1}
    end

    test "rejects a malformed use" do
      for source <- [~s|(trace "x")|, ~s|(trace "x" 1 2)|, ~s|(trace . "x")|] do
        assert {:error, %Schooner.Eval.Error{reason: {:bad_special_form, "trace"}} = e} =
                 eval(source, file: "t.scm")

        assert at(e.location) == {"t.scm", 2, 1}
      end
    end
  end

  describe "trace and tail calls" do
    # As in `Schooner.EvalTcoTest`: 1M frames would blow well past this.
    defp assert_bounded(fun) do
      fun.()
      {:total_heap_size, heap} = Process.info(self(), :total_heap_size)
      assert heap < 5_000_000, "heap grew to #{heap} words — TCO likely broken"
    end

    for debug <- [false, true] do
      test "a deep tail loop wrapped in trace runs in bounded memory (debug: #{debug})" do
        source = """
        (define (loop n) (if (= n 0) 'done (loop (- n 1))))
        (trace "loop" (loop 1000000))
        """

        assert_bounded(fn -> assert {:ok, _} = eval(source, debug: unquote(debug)) end)
        assert_received {:schooner_debug, :trace, "loop: done", _}
      end

      test "a tail loop that traces its argument runs in bounded memory (debug: #{debug})" do
        counter = :counters.new(1, [])
        sink = fn _ -> :counters.add(counter, 1, 1) end

        source = """
        (import (schooner debug))
        (define (loop n) (if (= n 0) 'done (loop (trace "n" (- n 1)))))
        (loop 300000)
        """

        assert_bounded(fn ->
          assert {:ok, _} = Schooner.eval(source, env(sink), debug: unquote(debug))
        end)

        assert :counters.get(counter, 1) == 300_000
      end
    end
  end

  describe "print" do
    test "sends its arguments' display text, separated by spaces" do
      assert {:ok, :unspecified} = eval(~s|(print "pricing" 3 'lines #\\x "a\\nb")|)
      assert sent() == [{:print, "pricing 3 lines x a\nb"}]
    end

    test "with no arguments sends empty text" do
      assert {:ok, _} = eval("(print)")
      assert sent() == [{:print, ""}]
    end

    test "is located at the print form" do
      assert {:ok, _} = eval(~s|\n  (print 1)|, file: "t.scm")
      assert_received {:schooner_debug, :print, "1", loc}
      assert at(loc) == {"t.scm", 3, 3}
    end

    test "rejects an improper argument list" do
      assert {:error, %Schooner.Eval.Error{reason: {:bad_special_form, "print"}}} =
               eval("(print 1 . 2)")
    end
  end

  describe "assert" do
    test "returns the expression's value when it is true" do
      assert {:ok, 3} = eval("(assert (+ 1 2))")
      assert {:ok, true} = eval("(assert #t (car '()))")
    end

    test "raises an error quoting the expression when it is false" do
      assert {:error, %Schooner.Error{} = e} = eval("(define total 0)\n(assert (> total 0))")
      assert e.value == {:error_obj, :user, "assertion failed: (> total 0)", []}
      assert e.message == "uncaught Scheme error: assertion failed: (> total 0)"
    end

    test "adds the message, evaluated only on failure" do
      assert {:error, e} =
               eval(~s|(define n 0)\n(assert (> n 0) (string-append "n is " (number->string n)))|)

      assert e.value == {:error_obj, :user, "assertion failed: (> n 0): n is 0", []}
    end

    test "displays a message that isn't a string" do
      assert {:error, e} = eval("(assert #f 'oops)")
      assert e.value == {:error_obj, :user, "assertion failed: #f: oops", []}
    end

    test "is catchable with guard" do
      source = """
      (guard (e ((error-object? e) (error-object-message e)))
        (assert (= 1 2)))
      """

      assert {:ok, "assertion failed: (= 1 2)"} = eval(source)
    end

    test "is located at the assert form" do
      assert {:error, e} = eval("(define total 0)\n  (assert (> total 0))", file: "t.scm")
      assert at(e.location) == {"t.scm", 3, 3}
      assert e.message == "t.scm:3:3: uncaught Scheme error: assertion failed: (> total 0)"
    end

    test "keeps its location through a guard that doesn't handle it" do
      source = "(guard (e ((string? e) e))\n  (assert #f))"
      assert {:error, e} = eval(source, file: "t.scm")
      assert at(e.location) == {"t.scm", 3, 3}
    end

    test "quotes the expression without hygiene marks inside a macro" do
      source = """
      (define-syntax check-positive
        (syntax-rules ()
          ((_ e) (let ((v e)) (assert (> v 0))))))
      (check-positive -1)
      """

      assert {:error, e} = eval(source)
      assert e.value == {:error_obj, :user, "assertion failed: (> v 0)", []}
    end

    test "rejects a malformed use" do
      for source <- ["(assert)", "(assert #t 1 2)"] do
        assert {:error, %Schooner.Eval.Error{reason: {:bad_special_form, "assert"}}} =
                 eval(source)
      end
    end
  end

  describe "sinks" do
    test "the logger sink logs at its level with the location and kind in metadata" do
      log =
        capture_log(
          [format: "$metadata| $message\n", metadata: [:schooner_debug, :schooner_location]],
          fn ->
            env = env({:logger, :info})
            source = ~s|(import (schooner debug))\n(trace "x" 1)\n(print "y")|
            assert {:ok, _} = Schooner.eval(source, env, file: "t.scm")
          end
        )

      assert log =~ "schooner_debug=trace schooner_location=t.scm:2:1 | x: 1"
      assert log =~ "schooner_debug=print schooner_location=t.scm:3:1 | y"
    end

    test "the pid sink sends kind, text and location" do
      assert {:ok, _} = eval(~s|(print "p")|, file: "t.scm")
      assert_received {:schooner_debug, :print, "p", %Location{file: "t.scm", line: 2, column: 1}}
    end

    test "the function sink is called with kind, text and location" do
      parent = self()
      sink = fn message -> send(parent, {:called, message}) end

      assert {:ok, 1} =
               Schooner.eval(~s|(import (schooner debug))\n(trace "f" 1)|, env(sink),
                 file: "t.scm"
               )

      assert_received {:called, %{kind: :trace, text: "f: 1", location: loc}}
      assert at(loc) == {"t.scm", 2, 1}
    end

    test "a sink that raises, exits or throws stops the script with a located error" do
      for {fun, banner} <- [
            {fn _ -> raise "boom" end, "** (RuntimeError) boom"},
            {fn _ -> exit(:gone) end, "** (exit) :gone"},
            {fn _ -> throw(:up) end, "** (throw) :up"}
          ] do
        source = ~s|(import (schooner debug))\n(trace "x" 1)|

        assert {:error, %PError{reason: {:debug_sink, "trace", ^banner}} = e} =
                 Schooner.eval(source, env(fun), file: "t.scm")

        assert at(e.location) == {"t.scm", 2, 1}
        assert e.message == "t.scm:2:1: the debug sink failed in `trace`: #{banner}"
      end
    end

    test "a guard doesn't catch a failing sink" do
      sink = fn _ -> raise "boom" end
      source = ~s|(import (schooner debug)) (guard (e (#t 'caught)) (print "x"))|

      assert {:error, %PError{reason: {:debug_sink, "print", _}}} =
               Schooner.eval(source, env(sink))
    end
  end

  describe "importing" do
    test "works under a rename and with only" do
      source = ~s|(import (rename (only (schooner debug) trace) (trace t))) (t "x" 1)|
      assert {:ok, 1} = Schooner.eval(source, env())
      assert sent() == [{:trace, "x: 1"}]
    end

    test "doesn't depend on the names the script binds" do
      source = """
      (import (schooner debug))
      (define (f lambda quote) (trace "args" (list lambda quote)))
      (f 1 2)
      """

      assert {:ok, _} = Schooner.eval(source, env())
      assert sent() == [{:trace, "args: (1 2)"}]
    end
  end

  describe "compiled scripts" do
    test "keep their locations and the sink they were compiled with" do
      source = ~s|(import (schooner debug))\n(trace "c" (+ 1 2))|
      compiled = Schooner.compile!(source, env(), file: "c.scm")

      run_env = Environment.new(pre_imports: [["scheme", "base"]])
      assert {:ok, 3} = Schooner.run_compiled(compiled, run_env)
      assert_received {:schooner_debug, :trace, "c: 3", loc}
      assert at(loc) == {"c.scm", 2, 1}
    end
  end

  describe "check/3" do
    test "reports nothing for a script that uses the library correctly" do
      source = """
      (import (schooner debug))
      (define (f x) (assert (> x 0) "positive") (print "f" x) (trace "f" (* x 2)))
      (f 1)
      """

      assert Schooner.check(source, env()) == []
    end

    test "reports problems inside the forms" do
      assert [%Schooner.Diagnostic{code: :unbound, message: "unbound variable: y"}] =
               Schooner.check(~s|(import (schooner debug)) (trace "x" (+ y 1))|, env())

      assert [%Schooner.Diagnostic{code: :syntax_error}] =
               Schooner.check(~s|(import (schooner debug)) (trace "x")|, env())
    end
  end

  describe "guides/tooling.md" do
    @guide File.read!("guides/tooling.md")

    setup do
      [section] = Regex.run(~r/## Tracing and assertions.*?(?=\n## )/s, @guide)
      [_, script] = Regex.run(~r/```scheme\n(.*?)```/s, section)
      %{section: section, script: script}
    end

    test "the pid sink example", %{script: script} do
      env = env()

      assert {:ok, 30} =
               Schooner.eval(script <> "(order-total '((10 . 3)))", env,
                 file: "scripts/order.scm"
               )

      assert_received {:schooner_debug, :print, "pricing 1 lines", _location}
      assert_received {:schooner_debug, :trace, "line-total: 30", %Location{line: 4}}
    end

    test "the failed assertion example", %{section: section, script: script} do
      [_, message] = Regex.run(~r/error\.message\n# => "(.*?)"\n/, section)

      assert {:error, error} =
               Schooner.eval(script <> "(order-total '((10 . 0)))", env(),
                 file: "scripts/order.scm"
               )

      assert error.message == message
    end

    test "the logger sink example", %{section: section, script: script} do
      assert section =~ "Schooner.Debug.library(sink: {:logger, :debug})"

      log =
        capture_log([level: :debug], fn ->
          assert {:ok, 30} =
                   Schooner.eval(script <> "(order-total '((10 . 3)))", env({:logger, :debug}))
        end)

      assert log =~ "pricing 1 lines"
      assert log =~ "line-total: 30"
    end

    test "marks the section available" do
      assert @guide =~ "**Status: Available** ([#137]"

      assert @guide =~
               "| 3 | [Tracing and assertions](#tracing-and-assertions) | Available |"
    end
  end
end
