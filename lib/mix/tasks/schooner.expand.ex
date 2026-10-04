defmodule Mix.Tasks.Schooner.Expand do
  @shortdoc "Prints the macro expansion of a Scheme script"

  @moduledoc """
  Prints what a Scheme script's macros expand to, with
  `Schooner.expand/3` and `Schooner.Pretty`, without running it.

      $ mix schooner.expand -e "(when (> n 0) (go n))"
      (if (> n 0) (begin (go n)))

  Give either a file or, with `-e`, the source itself. The expanded
  top-level forms are printed one after another, with a blank line
  between them. An identifier a macro introduces is printed with a
  number, such as `tmp·1`, so it can be told apart from the script's
  own `tmp`.

  ## Options

    * `-e`, `--eval SOURCE` — expand `SOURCE` instead of a file.
    * `--env Mod.fun` — expand against the `Schooner.Environment`
      returned by the zero-arity function `Mod.fun`. Without it, the
      environment is the one configured with

          config :schooner, :tooling_environment, {Mod, :fun, args}

      and without that, every standard library, all imported: the
      surface `Schooner.run/1` gives a script that imports nothing.
      The environment decides which macros are in scope, so prefer
      your application's real one.
    * `--once` — expand each macro use that is not inside another
      macro use once, leaving the macro uses in its output as they
      are.
    * `--trace` — before the result, print each macro use expanded,
      in order: its number, the macro's name and the location of the
      use, then the use and, after `=>`, what it expanded to.

          $ mix schooner.expand -e "(unless ok (fail))" --trace
          [1] unless at 1:1
              (unless ok (fail))
           => (if ok (begin) (begin (fail)))

          (if ok (begin) (begin (fail)))

    * `--plain` — print renamed identifiers by their names alone
      (`tmp`).
    * `--width N` — the line width to fit forms in. Defaults to 80.

  When the script can't be read or expanded, the task prints the error
  and exits with status 1.
  """

  use Mix.Task

  @switches [
    eval: :string,
    env: :string,
    once: :boolean,
    trace: :boolean,
    plain: :boolean,
    width: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches, aliases: [e: :eval])
    {source, file} = source!(opts[:eval], args)
    width = Keyword.get(opts, :width, 80)

    if width < 1, do: Mix.raise("--width must be a positive integer, got: #{width}")

    Mix.Schooner.start()
    environment = Mix.Schooner.environment!(opts[:env])
    step = if opts[:once], do: :once, else: :full
    trace? = opts[:trace] || false
    pretty = [width: width, names: if(opts[:plain], do: :plain, else: :marked)]

    case Schooner.expand(source, environment, file: file, step: step, trace: trace?) do
      {:ok, forms} -> Mix.shell().info(report(forms, [], pretty))
      {:ok, forms, steps} -> Mix.shell().info(report(forms, steps, pretty))
      {:error, e} -> Mix.raise(Schooner.format_error(e, source: source))
    end
  end

  defp source!(nil, [file]), do: {File.read!(file), file}
  defp source!(source, []) when is_binary(source), do: {source, nil}

  defp source!(_, _),
    do: Mix.raise(~s|mix schooner.expand expects one file, or -e "source"|)

  @doc false
  # The text printed for the expanded `forms` and, with `--trace`,
  # the `steps` that produced them, formatted with the `Schooner.Pretty`
  # options `pretty`.
  @spec report([Schooner.Value.t()], [Schooner.expansion_step()], keyword()) :: binary()
  def report(forms, steps, pretty) do
    steps =
      steps
      |> Enum.with_index(1)
      |> Enum.map(fn {step, i} -> step(step, i, pretty) end)

    result = Enum.map_join(forms, "\n\n", &Schooner.Pretty.format(&1, pretty))

    Enum.join(steps ++ [result], "\n\n")
  end

  defp step(step, i, pretty) do
    at = if step.location, do: " at #{step.location}", else: ""

    Enum.join(
      [
        "[#{i}] #{step.macro}#{at}",
        "    " <> indented(step.before, pretty),
        " => " <> indented(step.after, pretty)
      ],
      "\n"
    )
  end

  # `form` formatted to fit after four columns of indentation, with its
  # continuation lines indented to match.
  defp indented(form, pretty) do
    width = max(Keyword.fetch!(pretty, :width) - 4, 1)

    form
    |> Schooner.Pretty.format(Keyword.put(pretty, :width, width))
    |> String.replace("\n", "\n    ")
  end
end
