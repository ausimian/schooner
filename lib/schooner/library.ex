defmodule Schooner.Library do
  @moduledoc """
  Registry entries for r7rs libraries.

  A `%Schooner.Library{}` is the *result* of compiling a library — a
  frozen exports map plus the dependency list and provenance metadata
  the importer and the diagnostics need. It is not a representation of
  the library's source: the original datums and the expanded body AST
  are dropped after the body has run and the exports have been
  materialised. Closures that escape via `:exports` carry their own
  body AST inside `{:closure, params, body, env, name}`; macros survive
  as transformers.

  Names are canonical lists of segments where each segment is either a
  binary (Scheme-symbol form) or a non-negative integer. The reader
  will produce datum-form names like `[{:sym, "scheme"}, {:sym, "base"}]`
  once `import` and `define-library` land; this module accepts only
  the canonicalised form so the registry key is `==`-comparable.

  ## Registries and persistent storage

  A *registry* is a plain map of `name => %Schooner.Library{}`.
  `register/2` and `lookup/2` are pure and operate on a map the caller
  owns. The standard library registry — built once by
  `Schooner.Library.Standard.boot/0` at OTP application start — is
  stashed under the persistent term key `{Schooner.Library,
  :standard}`. `standard/0` reads it without copying, so spawned
  evaluator processes pay no cost to access it.
  """

  alias Schooner.Library.NotFoundError

  @persistent_key {__MODULE__, :standard}

  @enforce_keys [:name]
  defstruct name: nil,
            exports: %{},
            imports: [],
            source: :native,
            features: []

  @type segment :: binary() | non_neg_integer()
  @type name :: [segment(), ...]
  @type export :: {:var, term()} | {:macro, term()}
  @type source :: :native | {:file, binary(), term()}
  @type t :: %__MODULE__{
          name: name(),
          exports: %{binary() => export()},
          imports: [name()],
          source: source(),
          features: [atom()]
        }
  @type registry :: %{name() => t()}

  @doc """
  Build a library entry. `:name` is required; other fields default
  empty (`exports: %{}`, `imports: []`, `source: :native`,
  `features: []`).
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    name = opts |> Keyword.fetch!(:name) |> validate_name!()

    %__MODULE__{
      name: name,
      exports: opts |> Keyword.get(:exports, %{}) |> validate_exports!(),
      imports: opts |> Keyword.get(:imports, []) |> Enum.map(&validate_name!/1),
      source: opts |> Keyword.get(:source, :native) |> validate_source!(),
      features: opts |> Keyword.get(:features, []) |> validate_features!()
    }
  end

  @doc """
  Insert `library` into `registry`. Raises `ArgumentError` if a library
  with the same canonical name is already present — registries are
  append-only.
  """
  @spec register(registry(), t()) :: registry()
  def register(registry, %__MODULE__{name: name} = library) when is_map(registry) do
    case Map.has_key?(registry, name) do
      true ->
        raise ArgumentError, "library #{render_name(name)} is already registered"

      false ->
        Map.put(registry, name, library)
    end
  end

  @doc "Look up `name` in `registry`. Returns `{:ok, library}` or `:error`."
  @spec lookup(registry(), name()) :: {:ok, t()} | :error
  def lookup(registry, name) when is_map(registry) and is_list(name) do
    Map.fetch(registry, name)
  end

  @doc """
  Look up `name` or raise `Schooner.Library.NotFoundError` if absent.
  """
  @spec fetch!(registry(), name()) :: t()
  def fetch!(registry, name) do
    case lookup(registry, name) do
      {:ok, lib} -> lib
      :error -> raise NotFoundError, name: name
    end
  end

  @doc """
  Read the standard registry from persistent term storage. Returns
  `%{}` when the key is unset, which lets `Schooner.Library.Standard`
  build the first registry on top of an empty default.
  """
  @spec standard() :: registry()
  def standard, do: :persistent_term.get(@persistent_key, %{})

  @doc """
  Persist `registry` as the standard registry. Triggers a global
  literal-area GC if the key is being updated rather than created;
  callers expect to use this only at OTP application start.
  """
  @spec persist!(registry()) :: :ok
  def persist!(registry) when is_map(registry) do
    :persistent_term.put(@persistent_key, registry)
    :ok
  end

  @doc """
  Topologically sort `registry` by `:imports`. Returns the names in an
  order where every import precedes the library that imports it. Edges
  pointing at libraries not present in `registry` are silently
  skipped — `import` resolution surfaces those at use site.

  Returns `{:error, {:cycle, names}}` when `registry` contains an
  import cycle. `names` lists the cycle entry-to-cycle-back order so
  `(a) imports (b), (b) imports (a)` reports `[a, b, a]`.
  """
  @spec topo_sort(registry()) :: {:ok, [name()]} | {:error, {:cycle, [name()]}}
  def topo_sort(registry) when is_map(registry) do
    initial = {:ok, [], MapSet.new()}

    result =
      Enum.reduce_while(Map.keys(registry), initial, fn name, {:ok, acc, done} ->
        case visit(name, registry, [], done, acc) do
          {:ok, acc, done} -> {:cont, {:ok, acc, done}}
          {:error, _} = err -> {:halt, err}
        end
      end)

    case result do
      {:ok, acc, _done} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp visit(name, registry, stack, done, acc) do
    cond do
      MapSet.member?(done, name) ->
        {:ok, acc, done}

      name in stack ->
        cycle = Enum.drop_while(Enum.reverse(stack), &(&1 != name)) ++ [name]
        {:error, {:cycle, cycle}}

      true ->
        visit_unseen(name, registry, stack, done, acc)
    end
  end

  defp visit_unseen(name, registry, stack, done, acc) do
    case Map.fetch(registry, name) do
      {:ok, %__MODULE__{imports: imports}} ->
        case walk_imports(imports, registry, [name | stack], done, acc) do
          {:ok, acc, done} -> {:ok, [name | acc], MapSet.put(done, name)}
          {:error, _} = err -> err
        end

      :error ->
        {:ok, acc, done}
    end
  end

  defp walk_imports(imports, registry, stack, done, acc) do
    Enum.reduce_while(imports, {:ok, acc, done}, fn imp, {:ok, acc, done} ->
      case visit(imp, registry, stack, done, acc) do
        {:ok, _, _} = ok -> {:cont, ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Render `name` in `(scheme base)` form for diagnostics.
  """
  @spec render_name(name()) :: binary()
  def render_name(name) when is_list(name) do
    "(" <> Enum.map_join(name, " ", &render_segment/1) <> ")"
  end

  @doc """
  Convert a Scheme datum form of a library name (e.g. `(scheme base)`
  read as a cons-cell list of `{:sym, _}` segments) into the canonical
  registry-key form (`["scheme", "base"]`). Symbol segments become
  binaries; non-negative integer segments pass through.
  """
  @spec canonicalise_name(Schooner.Value.t()) :: name()
  def canonicalise_name(datum) do
    datum
    |> Schooner.Value.to_list()
    |> Enum.map(&canonical_segment!/1)
  end

  defp canonical_segment!({:sym, name}), do: name
  defp canonical_segment!(int) when is_integer(int) and int >= 0, do: int

  defp canonical_segment!(other) do
    raise ArgumentError,
          "library name segments must be symbols or non-negative integers, got #{inspect(other)}"
  end

  defp render_segment(seg) when is_binary(seg), do: seg
  defp render_segment(seg) when is_integer(seg), do: Integer.to_string(seg)

  defp validate_name!([_ | _] = name) do
    Enum.each(name, fn
      seg when is_binary(seg) ->
        :ok

      seg when is_integer(seg) and seg >= 0 ->
        :ok

      seg ->
        raise ArgumentError,
              "library name segment must be a binary or non-negative integer, got #{inspect(seg)}"
    end)

    name
  end

  defp validate_name!(other) do
    raise ArgumentError, "library name must be a non-empty list, got #{inspect(other)}"
  end

  defp validate_exports!(map) when is_map(map) do
    Enum.each(map, fn
      {k, {:var, _}} when is_binary(k) ->
        :ok

      {k, {:macro, _}} when is_binary(k) ->
        :ok

      bad ->
        raise ArgumentError,
              "library export must be {binary, {:var, _} | {:macro, _}}, got #{inspect(bad)}"
    end)

    map
  end

  defp validate_exports!(other) do
    raise ArgumentError, "library exports must be a map, got #{inspect(other)}"
  end

  defp validate_source!(:native), do: :native
  defp validate_source!({:file, path, _span} = src) when is_binary(path), do: src

  defp validate_source!(other) do
    raise ArgumentError,
          "library :source must be :native or {:file, path, span}, got #{inspect(other)}"
  end

  defp validate_features!(features) when is_list(features) do
    Enum.each(features, fn
      f when is_atom(f) -> :ok
      bad -> raise ArgumentError, "library feature must be an atom, got #{inspect(bad)}"
    end)

    features
  end

  defp validate_features!(other) do
    raise ArgumentError, "library :features must be a list of atoms, got #{inspect(other)}"
  end
end
