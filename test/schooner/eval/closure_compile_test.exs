defmodule Schooner.Eval.ClosureCompileTest do
  @moduledoc """
  `Schooner.Eval.compile/1` turns analysed IR into closures, with
  applications specialised on argument count. These tests pin the
  behaviour each specialisation must share with the general path, and
  that `%Schooner.Compiled{}` stays plain data.
  """

  use ExUnit.Case, async: true

  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  # An environment with a primitive that records the order in which its
  # argument expressions were evaluated.
  defp env_with_probe do
    pid = self()

    Schooner.Environment.new(
      pre_imports: [["scheme", "base"]],
      libraries: [
        Schooner.Host.library(
          primitives: [{"probe", 1, fn [tag] -> send(pid, {:probe, tag}) && tag end}]
        )
      ]
    )
  end

  defp probes do
    receive do
      {:probe, tag} -> [tag | probes()]
    after
      0 -> []
    end
  end

  describe "application at every arity" do
    for n <- 0..5 do
      @n n
      test "#{n} argument(s): head first, then arguments left to right" do
        args = Enum.map_join(1..@n//1, " ", &"(probe #{&1})")
        params = Enum.map_join(1..@n//1, " ", &"a#{&1}")

        src = """
        ((begin (probe 0) (lambda (#{params}) (list #{params}))) #{args})
        """

        assert Schooner.eval!(src, env_with_probe()) == Value.list(Enum.to_list(1..@n//1))
        assert probes() == Enum.to_list(0..@n)
      end
    end

    for n <- 0..5 do
      @n n
      test "#{n} argument(s): closure arity mismatch reports the supplied count" do
        args = Enum.map_join(1..@n//1, " ", &Integer.to_string/1)
        src = "((lambda (a b c d e f g) a) #{args})"

        e = assert_raise EvalError, fn -> Schooner.run!(src) end
        assert e.reason == {:arity_mismatch, nil, {:exact, 7}, @n}
      end
    end

    for n <- 1..5 do
      @n n
      test "#{n} argument(s): a multiple-value argument is rejected" do
        args = List.duplicate("1", @n - 1) ++ ["(values 1 2)"]
        src = "(list #{Enum.join(args, " ")})"

        e = assert_raise PError, fn -> Schooner.run!(src) end
        assert e.reason == {:wrong_value_count, 2, 1}
      end
    end
  end

  describe "if" do
    test "a single value wrapped by (values) is unwrapped before the test" do
      assert Schooner.run!("(if (values #f) 'yes 'no)") == Value.symbol("no")
      assert Schooner.run!("(if (values 0) 'yes 'no)") == Value.symbol("yes")
    end

    test "a multiple-value test is rejected" do
      e = assert_raise PError, fn -> Schooner.run!("(if (values 1 2) 'yes 'no)") end
      assert e.reason == {:wrong_value_count, 2, 1}
    end
  end

  describe "compiled programs" do
    test "%Compiled{} survives a term_to_binary round trip" do
      src = """
      (define (fact n) (if (< n 2) 1 (* n (fact (- n 1)))))
      (let loop ((i 0) (acc '()))
        (if (= i 3) (reverse acc) (loop (+ i 1) (cons (fact (+ i 5)) acc))))
      """

      env = Schooner.Environment.new(pre_imports: [["scheme", "base"]])
      compiled = Schooner.compile!(src, env)
      revived = compiled |> :erlang.term_to_binary() |> :erlang.binary_to_term()

      assert Schooner.run_compiled!(revived, env) == Value.list([120, 720, 5040])
    end
  end
end
