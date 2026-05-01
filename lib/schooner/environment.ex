defmodule Schooner.Environment do
  @moduledoc """
  Opaque embedding-friendly environment that bundles a runtime
  `Schooner.Env`, an expander `SyntaxEnv`, and a library registry.

  An `%Environment{}` is the recommended argument to
  `Schooner.eval/2,3` and `Schooner.eval!/2,3` for embedders. It
  carries everything needed to evaluate a script in a controlled
  surface — which standard libraries are reachable via `(import ...)`,
  which host libraries are pre-applied, which named host libraries
  are available for the script to import. The struct is opaque:
  embedders must not pattern-match on its internals; the public
  surface is `new/1`.

  ## Library composition

    * **Standard libraries** populate the registry from
      `Schooner.Library.standard/0`. The `:standard_libraries`
      option controls which ones are available. Default `:default`
      registers everything Schooner ships with; `:none` ships none;
      a list of canonical names like `[["scheme", "base"], ["scheme",
      "char"]]` ships exactly those.

    * **Named host libraries** (built with
      `Schooner.Host.library/1` and a non-empty `:name`) join the
      registry alongside the standard libraries. The script must
      `(import ...)` them to bring their bindings into scope.
      Sandbox-safe — the embedder controls the menu, the script
      controls which dishes it orders.

    * **Anonymous host libraries** (`name: []`) bypass the registry
      entirely. Their bindings are applied directly to the runtime
      env at construction time, so they are in scope from the
      script's first form without any `(import ...)`. **This is
      sandbox-loosening** — list anonymous libraries deliberately.

    * **`:pre_imports`** auto-apply specific named libraries to the
      runtime env, equivalent to the script having
      `(import (foo bar))` at the top. Useful when the embedder
      always wants a specific surface available without making the
      script repeat the import. Only canonical names are accepted
      at this level (no modifiers); use anonymous libraries or
      script-side `(import (only ...))` for finer control.

  ## Re-use across evaluations

  An `%Environment{}` can be passed to many `Schooner.eval/2,3`
  calls. The runtime `env`'s globals slot persists across
  evaluations, so a script's top-level `define`s remain visible to
  later scripts evaluated against the same environment. This is
  the embedding-friendly model for things like rule-loading: load
  rule definitions once, evaluate many trigger scripts that call
  them.

  Each call to `eval` snapshots and restores the per-process
  exception / continuation / parameter state, so leftover state
  from a script that escaped via `raise` does not bleed into the
  next call.
  """

  alias Schooner.Env
  alias Schooner.Expander
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Library
  alias Schooner.Library.Import, as: LibImport

  @enforce_keys [:env, :syntax_env, :registry]
  defstruct [:env, :syntax_env, :registry]

  @opaque t :: %__MODULE__{
            env: Env.t(),
            syntax_env: SyntaxEnv.t(),
            registry: Library.registry()
          }

  @doc false
  @spec env(t()) :: Env.t()
  def env(%__MODULE__{env: env}), do: env

  @doc false
  @spec syntax_env(t()) :: SyntaxEnv.t()
  def syntax_env(%__MODULE__{syntax_env: syntax_env}), do: syntax_env

  @doc false
  @spec registry(t()) :: Library.registry()
  def registry(%__MODULE__{registry: registry}), do: registry

  @standard_shortcuts %{
    base: ["scheme", "base"],
    cxr: ["scheme", "cxr"],
    char: ["scheme", "char"],
    inexact: ["scheme", "inexact"],
    complex: ["scheme", "complex"],
    write: ["scheme", "write"],
    read: ["scheme", "read"],
    "case-lambda": ["scheme", "case-lambda"],
    case_lambda: ["scheme", "case-lambda"],
    lazy: ["scheme", "lazy"]
  }

  @doc """
  Build a new `%Environment{}`.

  ## Options

    * `:standard_libraries` — controls which shipped libraries
      enter the registry. One of:
        * `:default` (default) — every shipped library.
        * `:none` — empty registry.
        * a list of canonical names (e.g.
          `[["scheme", "base"], ["scheme", "char"]]`) or atom
          shortcuts (`:base`, `:char`, `:inexact`, `:complex`,
          `:cxr`, `:write`, `:read`, `:lazy`, `:case_lambda` /
          `:"case-lambda"`).

    * `:libraries` — list of `t:Schooner.Library.t/0` (typically
      built via `Schooner.Host.library/1`). Named libraries join
      the registry; anonymous libraries (`name: []`) have their
      bindings applied directly to the runtime env.

    * `:pre_imports` — list of canonical library names to
      auto-import at construction time. Each name must resolve
      against the assembled registry (standard + named host
      libraries) — a missing name raises
      `Schooner.Library.NotFoundError`.

  Returns the constructed `%Environment{}`. Raises `ArgumentError`
  for malformed option values.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    standard = Keyword.get(opts, :standard_libraries, :default)
    libraries = Keyword.get(opts, :libraries, [])
    pre_imports = Keyword.get(opts, :pre_imports, [])

    standard_registry = standard_registry!(standard)
    {named_libs, anonymous_libs} = split_libraries!(libraries)

    registry = Enum.reduce(named_libs, standard_registry, &Library.register(&2, &1))

    env = Env.new()
    syntax_env = Expander.bootstrap_env()

    {env, syntax_env} = apply_anonymous!(anonymous_libs, env, syntax_env)
    {env, syntax_env} = apply_pre_imports!(pre_imports, registry, env, syntax_env)

    %__MODULE__{env: env, syntax_env: syntax_env, registry: registry}
  end

  defp standard_registry!(:default), do: Library.standard()
  defp standard_registry!(:none), do: %{}

  defp standard_registry!(names) when is_list(names) do
    full = Library.standard()

    Enum.reduce(names, %{}, fn name, acc ->
      canonical = canonical_standard_name!(name)

      case Map.fetch(full, canonical) do
        {:ok, lib} ->
          Map.put(acc, canonical, lib)

        :error ->
          raise ArgumentError,
                ":standard_libraries names a library that is not shipped: " <>
                  Library.render_name(canonical)
      end
    end)
  end

  defp standard_registry!(other) do
    raise ArgumentError,
          ":standard_libraries must be :default, :none, or a list, got #{inspect(other)}"
  end

  defp canonical_standard_name!(name) when is_atom(name) do
    case Map.fetch(@standard_shortcuts, name) do
      {:ok, canonical} ->
        canonical

      :error ->
        raise ArgumentError,
              ":standard_libraries shortcut #{inspect(name)} is not recognised"
    end
  end

  defp canonical_standard_name!(name) when is_list(name), do: name

  defp canonical_standard_name!(other) do
    raise ArgumentError,
          ":standard_libraries entry must be a canonical name list or atom shortcut, " <>
            "got #{inspect(other)}"
  end

  defp split_libraries!(libraries) when is_list(libraries) do
    Enum.reduce(libraries, {[], []}, fn
      %Library{name: []} = lib, {named, anon} ->
        {named, [lib | anon]}

      %Library{} = lib, {named, anon} ->
        {[lib | named], anon}

      bad, _ ->
        raise ArgumentError, ":libraries entry must be a Schooner.Library, got #{inspect(bad)}"
    end)
    |> then(fn {named, anon} -> {Enum.reverse(named), Enum.reverse(anon)} end)
  end

  defp split_libraries!(other) do
    raise ArgumentError, ":libraries must be a list, got #{inspect(other)}"
  end

  defp apply_anonymous!(anonymous_libs, env, syntax_env) do
    Enum.reduce(anonymous_libs, {env, syntax_env}, fn %Library{exports: exports}, {e, se} ->
      LibImport.apply_bindings(exports, e, se)
    end)
  end

  defp apply_pre_imports!([], _registry, env, syntax_env), do: {env, syntax_env}

  defp apply_pre_imports!(pre_imports, registry, env, syntax_env) when is_list(pre_imports) do
    bindings =
      Enum.reduce(pre_imports, %{}, fn name, acc ->
        canonical = canonical_pre_import_name!(name)
        lib = Library.fetch!(registry, canonical)
        Map.merge(acc, lib.exports)
      end)

    LibImport.apply_bindings(bindings, env, syntax_env)
  end

  defp apply_pre_imports!(other, _registry, _env, _syntax_env) do
    raise ArgumentError, ":pre_imports must be a list, got #{inspect(other)}"
  end

  defp canonical_pre_import_name!(name) when is_list(name), do: name

  defp canonical_pre_import_name!(other) do
    raise ArgumentError,
          ":pre_imports entry must be a canonical name list (e.g. " <>
            ~s|["myapp", "log"]| <> "), got #{inspect(other)}"
  end
end
