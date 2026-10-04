defmodule Mix.Tasks.Schooner.CheckTest do
  # Not async: some tests change the working directory or the
  # application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Schooner.Check
  alias Schooner.Diagnostic
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

    def empty, do: Environment.new(standard_libraries: :none)

    def chars, do: Environment.new(pre_imports: [["scheme", "base"], ["scheme", "char"]])

    def not_an_environment, do: :nope
  end

  @guide File.read!("guides/tooling.md")

  @moduletag :tmp_dir

  # Run the task, returning `{exit status, output}`.
  defp run_task(argv) do
    with_io(fn ->
      try do
        Check.run(argv)
        0
      catch
        :exit, {:shutdown, status} -> status
      end
    end)
  end

  defp write!(dir, name, source) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
    path
  end

  describe "text output" do
    test "prints each diagnostic and a summary, and fails on errors", %{tmp_dir: dir} do
      bad = write!(dir, "bad.scm", "(define (f x)\n  (+ x y))\n(car 1 2)")
      write!(dir, "good.scm", "(car '(1))")

      assert {1, output} = run_task([Path.join(dir, "*.scm")])

      assert output == """
             #{bad}:2:8: error[unbound]: unbound variable: y
             #{bad}:3:1: error[arity]: arity mismatch in `car`: expected 1, got 2
             2 errors in 1 file
             """
    end

    test "succeeds when nothing is found", %{tmp_dir: dir} do
      good = write!(dir, "good.scm", "(car '(1))")
      assert run_task([good]) == {0, "No problems found in 1 file\n"}
    end

    test "names the file of a diagnostic without a position" do
      d = %Diagnostic{severity: :error, code: :unbound, message: "m", location: nil}

      assert Check.report("text", [{"a.scm", [d]}]) ==
               "a.scm: error[unbound]: m\n1 error in 1 file"
    end

    test "counts warnings in the summary" do
      w = %Diagnostic{severity: :warning, code: :unbound, message: "m", location: nil}
      e = %{w | severity: :error}

      assert Check.report("text", [{"a.scm", [e, w]}, {"b.scm", [w]}, {"c.scm", []}]) =~
               ~r/\n1 error, 2 warnings in 2 files$/
    end
  end

  describe "--format json" do
    test "prints diagnostics and counts as one object", %{tmp_dir: dir} do
      bad = write!(dir, "bad.scm", "(import (nope))\n(car)")
      write!(dir, "good.scm", "(car '(1))")

      assert {1, output} = run_task([dir, "--format", "json"])

      assert JSON.decode!(output) == %{
               "diagnostics" => [
                 %{
                   "file" => bad,
                   "line" => 1,
                   "column" => 9,
                   "severity" => "error",
                   "code" => "unknown_library",
                   "message" => "library not found: (nope)"
                 },
                 %{
                   "file" => bad,
                   "line" => 2,
                   "column" => 1,
                   "severity" => "error",
                   "code" => "arity",
                   "message" => "arity mismatch in `car`: expected 1, got 0"
                 }
               ],
               "errors" => 2,
               "warnings" => 0,
               "files" => 2
             }
    end

    test "succeeds when nothing is found", %{tmp_dir: dir} do
      good = write!(dir, "good.scm", "1")
      assert {0, output} = run_task([good, "--format", "json"])

      assert JSON.decode!(output) == %{
               "diagnostics" => [],
               "errors" => 0,
               "warnings" => 0,
               "files" => 1
             }
    end

    test "uses null for an unknown position" do
      d = %Diagnostic{severity: :error, code: :unbound, message: "m", location: nil}

      assert %{"diagnostics" => [%{"line" => nil, "column" => nil}]} =
               JSON.decode!(Check.report("json", [{"a.scm", [d]}]))
    end
  end

  describe "exit status" do
    test "warnings fail only with --warnings-as-errors" do
      warning = %Diagnostic{severity: :warning, code: :unbound, message: "m"}
      error = %{warning | severity: :error}

      refute Check.failed?([], true)
      refute Check.failed?([warning], false)
      assert Check.failed?([warning], true)
      assert Check.failed?([error], false)
    end

    test "--warnings-as-errors is accepted", %{tmp_dir: dir} do
      good = write!(dir, "good.scm", "1")
      assert {0, _} = run_task([good, "--warnings-as-errors"])
    end
  end

  describe "arguments" do
    test "a directory means every .scm file under it", %{tmp_dir: dir} do
      write!(dir, "a.scm", "1")
      write!(dir, "nested/b.scm", "2")
      write!(dir, "notes.txt", "(")
      File.mkdir_p!(Path.join(dir, "dir.scm"))

      assert run_task([dir]) == {0, "No problems found in 2 files\n"}
    end

    test "fails when an argument matches no files", %{tmp_dir: dir} do
      assert_raise Mix.Error, ~r/no files match/, fn -> run_task([Path.join(dir, "*.scm")]) end
    end

    test "fails without arguments" do
      assert_raise Mix.Error, ~r/at least one/, fn -> run_task([]) end
    end

    test "fails on an unknown format", %{tmp_dir: dir} do
      good = write!(dir, "good.scm", "1")
      assert_raise Mix.Error, ~r/--format/, fn -> run_task([good, "--format", "xml"]) end
    end
  end

  describe "environment resolution" do
    setup %{tmp_dir: dir} do
      # Needs `(scheme char)`, which the default environment imports.
      %{script: write!(dir, "upcase.scm", "(char-upcase #\\a)")}
    end

    test "defaults to every standard library, all imported", %{script: script} do
      assert {0, _} = run_task([script])
    end

    test "--env names a zero-arity function", %{script: script} do
      assert {1, output} = run_task([script, "--env", "#{inspect(Envs)}.empty"])
      assert output =~ "error[unbound]: unbound variable: char-upcase"
    end

    test "--env must name a function that exists", %{script: script} do
      assert_raise Mix.Error, ~r/Envs.missing\/0 is undefined/, fn ->
        run_task([script, "--env", "#{inspect(Envs)}.missing"])
      end

      assert_raise Mix.Error, ~r/expects Module.function/, fn ->
        run_task([script, "--env", "environment"])
      end
    end

    test "--env must return an environment", %{script: script} do
      assert_raise Mix.Error, ~r/expected a Schooner.Environment, got: :nope/, fn ->
        run_task([script, "--env", "#{inspect(Envs)}.not_an_environment"])
      end
    end

    test "falls back to config :schooner, :tooling_environment", %{script: script} do
      Application.put_env(:schooner, :tooling_environment, {Envs, :empty, []})
      on_exit(fn -> Application.delete_env(:schooner, :tooling_environment) end)

      assert {1, _} = run_task([script])
      assert {0, _} = run_task([script, "--env", "#{inspect(Envs)}.chars"])

      Application.put_env(:schooner, :tooling_environment, :bad)
      assert_raise Mix.Error, ~r/must be \{module, function, args\}/, fn -> run_task([script]) end
    end
  end

  describe "guides/tooling.md" do
    setup do
      [_, pricing] =
        Regex.run(~r/and one script, `scripts\/pricing.scm`:\n\n```scheme\n(.*?)```/s, @guide)

      [section] = Regex.run(~r/## Checking scripts before they run.*?(?=\n## |\z)/s, @guide)
      %{pricing: pricing, section: section}
    end

    test "the check/3 example", %{section: section} do
      [_, call, expected] =
        Regex.run(~r/```elixir\n(Schooner\.check.*?)\n# => (.*?)\n```/s, section)

      call = String.replace(call, "MyApp.Scripts.environment()", "#{inspect(Envs)}.scripts()")
      {diagnostics, _} = Code.eval_string(call)
      {expected, _} = expected |> String.replace(~r/^#\s*/m, "") |> Code.eval_string()

      assert diagnostics == expected
    end

    test "the mix schooner.check example", %{tmp_dir: dir, pricing: pricing, section: section} do
      [_, argv, expected] =
        Regex.run(~r/```console\n\$ mix schooner.check (.*?)\n(.*?)```/s, section)

      [_, draft] = Regex.run(~r/Schooner\.check\(~s\|(.*?)\|/, section)

      write!(dir, "scripts/pricing.scm", pricing)
      write!(dir, "scripts/draft.scm", draft)
      write!(dir, "scripts/discounts.scm", "(import (myapp promos))\n")

      argv =
        argv
        |> OptionParser.split()
        |> Enum.map(&String.replace(&1, "MyApp.Scripts.environment", "#{inspect(Envs)}.scripts"))

      assert File.cd!(dir, fn -> run_task(argv) end) == {1, expected}
    end
  end
end
