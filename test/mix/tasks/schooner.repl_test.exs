defmodule Mix.Tasks.Schooner.ReplTest do
  # Not async: some tests change the working directory or the
  # application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Schooner.Repl
  alias Schooner.Environment
  alias Schooner.Host

  defmodule Envs do
    @moduledoc false

    # Like `MyApp.Scripts.environment/0` in guides/tooling.md.
    def scripts do
      Environment.new(
        standard_libraries: [:base, :char, :write],
        pre_imports: [["scheme", "base"]],
        libraries: [
          Host.library(
            name: ["myapp", "catalog"],
            primitives: [{"unit-price", 1, fn _ -> 10 end}]
          )
        ]
      )
    end

    def not_an_environment, do: :nope
  end

  @guide File.read!("guides/tooling.md")

  @moduletag :tmp_dir

  # Run the task with `input` on standard input, which isn't a
  # terminal, so it reads lines.
  defp run_task(argv, input), do: capture_io(input, fn -> Repl.run(argv) end)

  test "evaluates what it reads against the environment" do
    output = run_task(["--env", "#{inspect(Envs)}.scripts"], "(+ 1 2)\n(char-upcase #\\a)\n")

    assert output == """
           #{Repl.banner("#{inspect(Envs)}.scripts")}
           schooner> 3
           schooner> error: unbound variable: char-upcase
           schooner> \n\
           """
  end

  test "the banner names the environment" do
    version = Application.spec(:schooner, :vsn)

    assert Repl.banner("MyApp.Scripts.environment") ==
             "Schooner #{version} — environment: MyApp.Scripts.environment/0. ,help for commands."

    assert Repl.banner(nil) =~ "environment: every standard library."
  end

  test "without --env, uses the configured environment" do
    Application.put_env(:schooner, :tooling_environment, {Envs, :scripts, []})

    try do
      output = run_task([], "(char-upcase #\\a)\n")
      assert output =~ "environment: #{inspect(Envs)}.scripts/0."
      assert output =~ "error: unbound variable: char-upcase"
    after
      Application.delete_env(:schooner, :tooling_environment)
    end
  end

  test "without --env or config, every standard library is imported" do
    assert run_task([], "(char-upcase #\\a)\n") =~ "schooner> #\\A\n"
  end

  test "--load evaluates files first, in order", %{tmp_dir: dir} do
    a = Path.join(dir, "a.scm")
    b = Path.join(dir, "b.scm")
    File.write!(a, "(define x 1)")
    File.write!(b, "(define y (+ x 1))")

    assert run_task(["--load", a, "--load", b], "y\n") =~ "schooner> 2\n"
  end

  test "--debug shows backtraces" do
    output = run_task(["--debug"], "(define (f x) (car x))\n(f 1)\n")
    assert output =~ "Scheme backtrace (most recent first):\n  car  1:15 (tail call)\n  f    1:1"
  end

  test "rejects a bad --env, and arguments" do
    assert_raise Mix.Error, ~r/expected a Schooner.Environment/, fn ->
      run_task(["--env", "#{inspect(Envs)}.not_an_environment"], "")
    end

    assert_raise Mix.Error, ~r/takes no arguments/, fn -> run_task(["x.scm"], "") end
  end

  describe "guides/tooling.md" do
    test "the mix schooner.repl transcript", %{tmp_dir: dir} do
      [_, pricing] =
        Regex.run(~r/and one script, `scripts\/pricing.scm`:\n\n```scheme\n(.*?)```/s, @guide)

      [section] = Regex.run(~r/## The REPL\n.*?(?=\n## )/s, @guide)

      [_, argv, transcript] =
        Regex.run(~r/```console\n\$ mix schooner.repl (.*?)\n(.*?)```/s, section)

      File.mkdir_p!(Path.join(dir, "scripts"))
      File.write!(Path.join(dir, "scripts/pricing.scm"), pricing)

      env = "#{inspect(Envs)}.scripts"
      argv = argv |> String.replace("MyApp.Scripts.environment", env) |> OptionParser.split()

      # What the transcript typed, and what the REPL wrote without the
      # echo of it, which a terminal adds.
      lines = String.split(transcript, "\n", trim: true)
      prompt = ~r/^(schooner> |     \.\.\.> )/
      input = for line <- lines, line =~ prompt, do: [String.replace(line, prompt, ""), "\n"]

      expected =
        Enum.map(lines, fn line ->
          case Regex.run(prompt, line) do
            [prompt, _] -> prompt
            nil -> line <> "\n"
          end
        end)

      output = File.cd!(dir, fn -> run_task(argv, IO.iodata_to_binary(input)) end)

      assert normalise(output, env) == normalise(IO.iodata_to_binary(expected), env)
    end

    test "marks the section available" do
      assert @guide =~ "**Status: Available** ([#139]"
      assert @guide =~ "| 5 | [The REPL](#the-repl) | Available |"
    end
  end

  # The output with the parts that change from run to run, or with the
  # environment's name, made the same.
  defp normalise(output, env) do
    output
    |> String.replace(~r/Schooner \S+ —/, "Schooner VERSION —")
    |> String.replace("MyApp.Scripts.environment", env)
    |> String.replace(~r/; \d+\.\dms, \d+ reductions/, "; TIME")
  end
end
