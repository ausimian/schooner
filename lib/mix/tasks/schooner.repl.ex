defmodule Mix.Tasks.Schooner.Repl do
  @shortdoc "Starts an interactive Scheme session"

  @moduledoc """
  Starts an interactive session against your application's real
  environment, built on `Schooner.Session`. Something that works here
  works in production, and something that's unbound in production is
  unbound here too.

      $ mix schooner.repl --env MyApp.Scripts.environment
      Schooner 1.1.0 — environment: MyApp.Scripts.environment/0. ,help for commands.
      schooner> (define (with-shipping x)
           ...>   (+ x 5))
      schooner> (with-shipping 30)
      35

  Definitions, imports and `define-syntax` macros persist from one
  entry to the next. An entry that ends inside an open form continues
  on the next line, and in a terminal that line starts indented to
  where the code goes, as `Schooner.Pretty` would lay it out: a body
  two columns in, the arguments of a call under the first. Tab
  re-indents a line, Up and Down recall earlier entries, and Ctrl-C
  interrupts an evaluation that runs too long, leaving the session as
  it was before it. Ctrl-D or `,quit` leaves.

  An error is printed, and the session carries on.

  ## Commands

    * `,env [prefix]` — list the bindings in scope, or those whose name
      starts with `prefix`: each one's name, the library it comes from,
      and what it is.
    * `,expand <form>` — show what `<form>` expands to, with the
      session's macros.
    * `,time <form>` — evaluate `<form>` and report its wall time and
      reductions.
    * `,load <file>` — evaluate a file into the session.
    * `,help`, `,quit`.

  ## Options

    * `--env Mod.fun` — evaluate against the `Schooner.Environment`
      returned by the zero-arity function `Mod.fun`. Without it, the
      environment is the one configured with

          config :schooner, :tooling_environment, {Mod, :fun, args}

      and without that, every standard library, all imported: the
      surface `Schooner.run/1` gives a script that imports nothing.
    * `--load FILE` — evaluate `FILE` into the session before the
      first prompt. Repeat it to load several, in order.
    * `--debug` — evaluate with `debug: true`, so errors carry their
      location and a Scheme backtrace.

  When standard input isn't a terminal, the task reads whole lines,
  without editing or indenting them, so you can pipe a script in.
  Ctrl-C then reaches the BEAM, as in any other mix task.
  """

  use Mix.Task

  alias Schooner.REPL
  alias Schooner.REPL.Terminal

  @switches [env: :string, load: :keep, debug: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    if args != [],
      do: Mix.raise("mix schooner.repl takes no arguments, got: #{Enum.join(args, " ")}")

    Mix.Schooner.start()
    env = opts[:env]

    repl_opts = [
      environment: fn -> Mix.Schooner.environment!(env) end,
      session: [debug: opts[:debug] || false],
      load: Keyword.get_values(opts, :load),
      banner: banner(env),
      columns: fn -> Terminal.columns(:stdio) end
    ]

    case Terminal.open() do
      {:ok, terminal} ->
        try do
          REPL.run([mode: :editor] ++ repl_opts)
        after
          Terminal.close(terminal)
        end

      :error ->
        REPL.run([mode: :line] ++ repl_opts)
    end
  end

  @doc false
  # The line the REPL starts with, naming the environment `--env env`
  # chooses.
  @spec banner(binary() | nil) :: binary()
  def banner(env) do
    version = Application.spec(:schooner, :vsn)
    "Schooner #{version} — environment: #{describe(env)}. ,help for commands."
  end

  defp describe(env) when is_binary(env), do: env <> "/0"

  defp describe(nil) do
    case Application.fetch_env(:schooner, :tooling_environment) do
      {:ok, {module, fun, args}} when is_atom(module) and is_atom(fun) and is_list(args) ->
        Exception.format_mfa(module, fun, length(args))

      _ ->
        "every standard library"
    end
  end
end
