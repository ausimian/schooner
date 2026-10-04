defmodule Mix.Schooner do
  @moduledoc false

  # Helpers shared by Schooner's mix tasks.

  alias Schooner.Environment
  alias Schooner.Library

  @doc """
  Start Schooner, after loading and compiling the project, so a task
  can build environments from the project's code.
  """
  @spec start() :: :ok
  def start do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:schooner)
    :ok
  end

  @doc """
  The `Schooner.Environment` a tooling task works against, first match
  wins:

    1. `env`, the value of an `--env Mod.fun` option: a zero-arity
       function returning a `Schooner.Environment`;
    2. `config :schooner, :tooling_environment, {Mod, :fun, args}`;
    3. every standard library, all imported, the surface
       `Schooner.run/1` gives a script that imports nothing.

  Raises `Mix.Error` when the named function is missing or does not
  return an environment.
  """
  @spec environment!(binary() | nil) :: Environment.t()
  def environment!(env) when is_binary(env) do
    case String.split(env, ".") |> Enum.split(-1) do
      {[_ | _] = module_parts, [fun]} when fun != "" ->
        module = Module.concat(module_parts)
        call!(module, String.to_atom(fun), [], "--env #{env}")

      _ ->
        Mix.raise("--env expects Module.function, got: #{env}")
    end
  end

  def environment!(nil) do
    case Application.fetch_env(:schooner, :tooling_environment) do
      {:ok, {module, fun, args}} when is_atom(module) and is_atom(fun) and is_list(args) ->
        call!(module, fun, args, "config :schooner, :tooling_environment")

      {:ok, other} ->
        Mix.raise(
          "config :schooner, :tooling_environment must be {module, function, args}, got: " <>
            inspect(other)
        )

      :error ->
        Environment.new(pre_imports: Map.keys(Library.standard()))
    end
  end

  defp call!(module, fun, args, source) do
    Code.ensure_loaded(module)

    unless function_exported?(module, fun, length(args)) do
      Mix.raise("#{source}: #{Exception.format_mfa(module, fun, length(args))} is undefined")
    end

    case apply(module, fun, args) do
      %Environment{} = environment ->
        environment

      other ->
        Mix.raise("#{source}: expected a Schooner.Environment, got: #{inspect(other)}")
    end
  end
end
