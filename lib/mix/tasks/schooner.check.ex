defmodule Mix.Tasks.Schooner.Check do
  @shortdoc "Checks Scheme scripts without running them"

  @moduledoc """
  Checks Scheme scripts for problems without running them, with
  `Schooner.check/3`.

      $ mix schooner.check "scripts/**/*.scm" --env MyApp.Scripts.environment
      scripts/discounts.scm:1:9: error[unknown_library]: library not found: (myapp promos)
      scripts/draft.scm:1:27: error[unbound]: unbound variable: unit-prise
      2 errors in 2 files

  Each argument is a file, a directory (every `.scm` file under it) or a
  glob. Quote globs so the task expands them rather than the shell.
  The task fails when an argument matches no files.

  ## Options

    * `--env Mod.fun` — check against the `Schooner.Environment`
      returned by the zero-arity function `Mod.fun`. Without it, the
      environment is the one configured with

          config :schooner, :tooling_environment, {Mod, :fun, args}

      and without that, every standard library, all imported: the
      surface `Schooner.run/1` gives a script that imports nothing.
      Prefer your application's real environment, which is usually
      much narrower.
    * `--format text|json` — `text` (the default) prints one line per
      diagnostic, `file:line:col: severity[code]: message`, and a
      summary. `json` prints one JSON object:

          {"diagnostics": [{"file": "scripts/draft.scm", "line": 1, "column": 27,
                            "severity": "error", "code": "unbound",
                            "message": "unbound variable: unit-prise"}],
           "errors": 1, "warnings": 0, "files": 2}

      `files` counts the files checked. `line` and `column` are `null`
      when the position is unknown. The task keeps compiler progress
      out of the JSON, but Mix may compile dependencies before the
      task starts, so run `mix compile` first when another program
      reads the output.
    * `--warnings-as-errors` — fail when there are warnings, too.

  The task exits with status 1 when it finds an error, and 0
  otherwise.
  """

  use Mix.Task

  alias Schooner.Diagnostic

  @switches [env: :string, format: :string, warnings_as_errors: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    format = Keyword.get(opts, :format, "text")

    unless format in ["text", "json"] do
      Mix.raise("--format must be text or json, got: #{format}")
    end

    if args == [] do
      Mix.raise("mix schooner.check expects at least one file, directory or glob")
    end

    files = Enum.flat_map(args, &expand_path!/1) |> Enum.uniq()

    # Compiling the project prints progress, which would corrupt the
    # JSON. `Mix.Shell.Quiet` still prints errors.
    if format == "json", do: quietly(&Mix.Schooner.start/0), else: Mix.Schooner.start()
    environment = Mix.Schooner.environment!(opts[:env])

    results =
      Enum.map(files, fn file ->
        {file, Schooner.check(File.read!(file), environment, file: file)}
      end)

    Mix.shell().info(report(format, results))

    if failed?(Enum.flat_map(results, &elem(&1, 1)), opts[:warnings_as_errors] || false) do
      exit({:shutdown, 1})
    end
  end

  defp expand_path!(arg) do
    pattern = if File.dir?(arg), do: Path.join(arg, "**/*.scm"), else: arg
    matches = pattern |> Path.wildcard() |> Enum.filter(&File.regular?/1)

    if matches == [], do: Mix.raise("no files match #{arg}")
    Enum.sort(matches)
  end

  defp quietly(fun) do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Quiet)

    try do
      fun.()
    after
      Mix.shell(shell)
    end
  end

  @doc false
  # Whether `diagnostics` fail the check.
  @spec failed?([Diagnostic.t()], boolean()) :: boolean()
  def failed?(diagnostics, warnings_as_errors) do
    Enum.any?(diagnostics, fn %Diagnostic{severity: severity} ->
      severity == :error or warnings_as_errors
    end)
  end

  @doc false
  # The report for `results`, a list of `{file, diagnostics}`, in
  # `format`.
  @spec report(binary(), [{binary(), [Diagnostic.t()]}]) :: binary()
  def report("text", results) do
    lines =
      for {file, diagnostics} <- results, d <- diagnostics do
        case d.location do
          nil -> "#{file}: " <> Diagnostic.format(d)
          _ -> Diagnostic.format(d)
        end
      end

    Enum.join(lines ++ [summary(results)], "\n")
  end

  def report("json", results) do
    diagnostics = for {file, ds} <- results, d <- ds, do: json_diagnostic(file, d)
    {errors, warnings} = counts(results)

    JSON.encode!(%{
      diagnostics: diagnostics,
      errors: errors,
      warnings: warnings,
      files: length(results)
    })
  end

  defp json_diagnostic(file, %Diagnostic{location: location} = d) do
    %{
      file: file,
      line: location && location.line,
      column: location && location.column,
      severity: d.severity,
      code: d.code,
      message: d.message
    }
  end

  defp summary(results) do
    case counts(results) do
      {0, 0} ->
        "No problems found in #{plural(length(results), "file")}"

      {errors, warnings} ->
        with_problems = Enum.count(results, fn {_file, ds} -> ds != [] end)

        counts =
          [{errors, "error"}, {warnings, "warning"}]
          |> Enum.reject(fn {n, _} -> n == 0 end)
          |> Enum.map_join(", ", fn {n, word} -> plural(n, word) end)

        "#{counts} in #{plural(with_problems, "file")}"
    end
  end

  defp counts(results) do
    diagnostics = Enum.flat_map(results, &elem(&1, 1))
    errors = Enum.count(diagnostics, &(&1.severity == :error))
    {errors, length(diagnostics) - errors}
  end

  defp plural(1, word), do: "1 #{word}"
  defp plural(n, word), do: "#{n} #{word}s"
end
