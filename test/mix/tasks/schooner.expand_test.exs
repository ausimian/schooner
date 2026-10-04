defmodule Mix.Tasks.Schooner.ExpandTest do
  # Not async: a test changes the application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Schooner.Expand
  alias Schooner.Environment

  defmodule Envs do
    @moduledoc false

    def bare, do: Environment.new(standard_libraries: :none)
  end

  @guide File.read!("guides/tooling.md")

  @moduletag :tmp_dir

  defp run_task(argv), do: capture_io(fn -> Expand.run(argv) end)

  test "prints the expanded forms of -e source, a blank line apart" do
    assert run_task(["-e", "(define x (when a b))\n(unless c d)"]) == """
           (define x (if a (begin b)))

           (if c (begin) (begin d))
           """
  end

  test "expands a file", %{tmp_dir: dir} do
    path = Path.join(dir, "s.scm")
    File.write!(path, "(define-syntax two (syntax-rules () ((_) 2)))\n(list (two))")

    assert run_task([path]) == "(list 2)\n"
    assert run_task([path, "--trace"]) =~ "[1] two at #{path}:2:7\n"
  end

  test "--once, --plain and --width" do
    assert run_task(["-e", "(or a b)", "--once"]) == "(let·1 ((t·1 a)) (if t·1 t·1 (or·1 b)))\n"
    assert run_task(["-e", "(or a b)", "--once", "--plain"]) == "(let ((t a)) (if t t (or b)))\n"

    assert run_task(["-e", "(or a b)", "--width", "20"]) == """
           ((lambda (t·1)
              (if t·1 t·1 b))
            a)
           """
  end

  test "--trace lists each step before the result" do
    assert run_task(["-e", "(and a (or b))", "--trace"]) == """
           [1] and at 1:1
               (and a (or b))
            => (if a (and·1 (or b)) #f)

           [2] and at 1:1
               (and·1 (or b))
            => (or b)

           [3] or at 1:8
               (or b)
            => b

           (if a b #f)
           """
  end

  test "--trace fits the forms in the width after their indentation" do
    output =
      run_task([
        "-e",
        "(when (some-test) (first-thing) (second-thing))",
        "--trace",
        "--width",
        "30"
      ])

    assert output == """
           [1] when at 1:1
               (when (some-test)
                 (first-thing)
                 (second-thing))
            => (if (some-test)
                   (begin
                     (first-thing)
                     (second-thing)))

           (if (some-test)
               (begin
                 (first-thing)
                 (second-thing)))
           """
  end

  test "an error is printed with an excerpt, and fails" do
    assert_raise Mix.Error, "1:1: malformed `if` form\n  |\n1 | (if)\n  | ^", fn ->
      run_task(["-e", "(if)"])
    end
  end

  test "arguments" do
    for argv <- [[], ["a.scm", "b.scm"], ["a.scm", "-e", "1"]] do
      assert_raise Mix.Error, ~r/expects one file, or -e/, fn -> run_task(argv) end
    end

    assert_raise Mix.Error, ~r/--width must be a positive integer/, fn ->
      run_task(["-e", "1", "--width", "0"])
    end
  end

  test "resolves the environment like mix schooner.check" do
    source = "(import (scheme case-lambda)) (case-lambda ((x) x))"

    assert run_task(["-e", source]) =~ "(lambda args·1"

    assert_raise Mix.Error, ~r/library not found: \(scheme case-lambda\)/, fn ->
      run_task(["-e", source, "--env", "#{inspect(Envs)}.bare"])
    end

    Application.put_env(:schooner, :tooling_environment, {Envs, :bare, []})
    on_exit(fn -> Application.delete_env(:schooner, :tooling_environment) end)
    assert_raise Mix.Error, ~r/library not found/, fn -> run_task(["-e", source]) end
  end

  describe "guides/tooling.md" do
    test "the mix schooner.expand example" do
      [section] = Regex.run(~r/## Inspecting macro expansion.*?(?=\n## )/s, @guide)

      [_, argv, expected] =
        Regex.run(~r/```console\n\$ mix schooner.expand (.*?)\n(.*?)```/s, section)

      assert run_task(OptionParser.split(argv)) == expected
    end
  end
end
