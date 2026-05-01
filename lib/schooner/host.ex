defmodule Schooner.Host do
  @moduledoc """
  Helpers for authoring Elixir-side host functions exposed to Scheme.

  Schooner does not auto-marshal across the host boundary. A host
  function has the same shape as a built-in primitive — it consumes a
  list of `Schooner.Value.t/0` arguments and returns a
  `Schooner.Value.t/0` — and uses the helpers in this module to move
  between Scheme values and idiomatic Elixir terms. The named
  constructors and accessors form the seam that future
  representation changes pivot on; even when the underlying impl is
  the identity (Schooner strings are bare Elixir binaries today),
  host code stays representation-agnostic by going through the
  helpers.

  ## Naming convention

  Asserting accessors (`to_*!/2`) raise `Schooner.Host.TypeError` when
  the input does not match the expected shape. They take a keyword
  argument with `:op` set to a host-supplied label for the call site
  so the error points at the wrapper, not the bare predicate.

  Total accessors (`to_*/1`) return `{:ok, term()} | :error` for the
  "branch on shape" case where a type mismatch is not an error.

  ## Recommended use pattern

  Several accessor names — `to_string/1`, `to_string!/2` — collide
  with `Kernel.to_string/1`. **Don't `import Schooner.Host`.** Use
  `alias Schooner.Host` and call the accessors as `Host.to_string!`
  etc.; the alias is one line and the call sites stay explicit.

  ## Worked example

      defmodule MyApp.SchemeLib do
        alias Schooner.Host

        @spec specs() :: [{binary(), Schooner.Value.arity_spec(), fun()}]
        def specs do
          [
            {"info", 1, &info/1},
            {"now-ms", 0, &now_ms/1}
          ]
        end

        defp info([msg]) do
          text = Host.to_string!(msg, op: "myapp/info")
          IO.puts(text)
          :unspecified
        end

        defp now_ms([]) do
          System.system_time(:millisecond)
        end
      end
  """

  alias Schooner.Host.TypeError
  alias Schooner.Library
  alias Schooner.Value

  # ---------------------------------------------------------------------------
  # Constructors — re-exports of Value's constructors so host code
  # never names the internal tag shape directly. Future representation
  # changes update Value; host code stays put.
  # ---------------------------------------------------------------------------

  @spec bool(boolean()) :: Value.bool_v()
  defdelegate bool(b), to: Value

  @spec string(binary()) :: Value.string_v()
  defdelegate string(s), to: Value

  @spec symbol(binary()) :: Value.sym_v()
  defdelegate symbol(name), to: Value

  @spec char(non_neg_integer()) :: Value.char_v()
  defdelegate char(cp), to: Value

  @spec pair(Value.t(), Value.t()) :: Value.pair_v()
  defdelegate pair(car, cdr), to: Value

  @spec list([Value.t()]) :: Value.t()
  defdelegate list(items), to: Value

  @spec vector([Value.t()]) :: Value.vector_v()
  defdelegate vector(items), to: Value

  @spec bytevector([byte()] | binary()) :: Value.bytevector_v()
  defdelegate bytevector(bs), to: Value

  @spec foreign(term()) :: Value.foreign_v()
  defdelegate foreign(term), to: Value

  @spec primitive(binary(), Value.arity_spec(), (list() -> Value.t())) :: Value.primitive_v()
  defdelegate primitive(name, arity, fun), to: Value

  # ---------------------------------------------------------------------------
  # Library builder
  # ---------------------------------------------------------------------------

  @doc """
  Build a `Schooner.Library` from host-supplied primitive specs and
  arbitrary value bindings.

  ## Options

    * `:name` — canonical library name as a list of binary or
      non-negative-integer segments. Defaults to `[]`, which marks
      the library as **anonymous**: it cannot be reached via Scheme
      `(import ...)`, and its bindings are applied directly to the
      runtime environment when the embedder lists it. Named
      libraries (e.g. `["myapp", "log"]`) are sandbox-safe — the
      script must explicitly `(import (myapp log))` to see them.

    * `:primitives` — list of `{name, arity, fun}` triples
      registered as `Schooner.Value.primitive/3` bindings. `arity`
      may be an integer, `{:at_least, n}`, or `{:between, lo, hi}`.
      `fun` must be `(list() -> Schooner.Value.t())` — the
      underlying primitive ABI.

    * `:values` — list of `{name, value}` pairs for arbitrary
      `Schooner.Value.t/0` bindings (constants, foreign-wrapped
      service handles, pre-built closures). Useful when the host
      wants to expose data, not just procedures.

  Names within a library must be unique across `:primitives` and
  `:values` combined; a collision raises `ArgumentError`.

  ## Examples

  Named library — script must import:

      Schooner.Host.library(
        name: ["myapp", "log"],
        primitives: [
          {"info", 1, &MyApp.SchemeLib.info/1}
        ]
      )

  Anonymous library — bindings auto-applied, no import required.
  Sandbox-loosening; list deliberately:

      Schooner.Host.library(
        primitives: [
          {"now-ms", 0, fn [] -> System.system_time(:millisecond) end}
        ]
      )
  """
  @spec library(keyword()) :: Library.t()
  def library(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, [])
    primitives = Keyword.get(opts, :primitives, [])
    values = Keyword.get(opts, :values, [])

    exports =
      %{}
      |> merge_primitives!(primitives)
      |> merge_values!(values)

    Library.new(name: name, exports: exports)
  end

  defp merge_primitives!(exports, primitives) when is_list(primitives) do
    Enum.reduce(primitives, exports, fn
      {pname, arity, fun}, acc when is_binary(pname) and is_function(fun, 1) ->
        put_export!(acc, pname, {:var, Value.primitive(pname, arity, fun)})

      bad, _acc ->
        raise ArgumentError,
              "host primitive must be {binary, arity_spec, (list() -> Value.t())}, " <>
                "got #{inspect(bad)}"
    end)
  end

  defp merge_primitives!(_exports, other) do
    raise ArgumentError, ":primitives must be a list, got #{inspect(other)}"
  end

  defp merge_values!(exports, values) when is_list(values) do
    Enum.reduce(values, exports, fn
      {vname, value}, acc when is_binary(vname) ->
        put_export!(acc, vname, {:var, value})

      bad, _acc ->
        raise ArgumentError, "host value binding must be {binary, value}, got #{inspect(bad)}"
    end)
  end

  defp merge_values!(_exports, other) do
    raise ArgumentError, ":values must be a list, got #{inspect(other)}"
  end

  defp put_export!(exports, name, binding) do
    case Map.fetch(exports, name) do
      :error ->
        Map.put(exports, name, binding)

      {:ok, _existing} ->
        raise ArgumentError,
              "duplicate host library export: #{inspect(name)} appears more than once " <>
                "in :primitives / :values"
    end
  end

  # ---------------------------------------------------------------------------
  # Asserting accessors — to_*!/2
  # ---------------------------------------------------------------------------

  @doc """
  Assert `value` is an exact integer and return the bare Elixir
  integer. Rejects rationals, floats, the float specials, and
  complex.
  """
  @spec to_integer!(Value.t(), keyword()) :: integer()
  def to_integer!(value, _opts) when is_integer(value), do: value
  def to_integer!(value, opts), do: type_error!(opts, "integer", value)

  @doc """
  Assert `value` is a bare inexact real and return the Elixir float.
  Rejects integers, rationals, the float specials (`+inf.0`,
  `-inf.0`, `+nan.0`), and complex. Hosts that want "any real
  number, coerced" should call `to_real!/2` instead.
  """
  @spec to_float!(Value.t(), keyword()) :: float()
  def to_float!(value, _opts) when is_float(value), do: value
  def to_float!(value, opts), do: type_error!(opts, "float", value)

  @doc """
  Assert `value` is any real number and return it as an Elixir
  number. Integers and floats pass through; rationals are coerced
  to their float approximation; the float specials are rejected
  (no plain BEAM-float representation).
  """
  @spec to_real!(Value.t(), keyword()) :: number()
  def to_real!(value, _opts) when is_integer(value) or is_float(value), do: value
  def to_real!({:rational, n, d}, _opts), do: n / d
  def to_real!(value, opts), do: type_error!(opts, "real", value)

  @doc """
  Assert `value` is a Scheme string and return the underlying Elixir
  binary. Rejects symbols, bytevectors, and any non-string.
  """
  @spec to_string!(Value.t(), keyword()) :: binary()
  def to_string!(value, _opts) when is_binary(value), do: value
  def to_string!(value, opts), do: type_error!(opts, "string", value)

  @doc """
  Assert `value` is a Scheme symbol and return its name as an Elixir
  binary.
  """
  @spec to_symbol_name!(Value.t(), keyword()) :: binary()
  def to_symbol_name!({:sym, name}, _opts), do: name
  def to_symbol_name!(value, opts), do: type_error!(opts, "symbol", value)

  @doc """
  Assert `value` is a Scheme character and return the codepoint
  integer.
  """
  @spec to_char!(Value.t(), keyword()) :: non_neg_integer()
  def to_char!({:char, cp}, _opts), do: cp
  def to_char!(value, opts), do: type_error!(opts, "character", value)

  @doc """
  Assert `value` is a Scheme boolean and return the Elixir
  `true | false`. Note: this differs from "truthy" — only `false`
  is Scheme-falsy, but every other value is *not* a Scheme boolean.
  Use `Schooner.Value.truthy?/1` for the truthiness test.
  """
  @spec to_bool!(Value.t(), keyword()) :: boolean()
  def to_bool!(value, _opts) when is_boolean(value), do: value
  def to_bool!(value, opts), do: type_error!(opts, "boolean", value)

  @doc """
  Assert `value` is a proper Scheme list and return the underlying
  Elixir list. Raises on improper lists and non-list values.
  """
  @spec to_list!(Value.t(), keyword()) :: [Value.t()]
  def to_list!([], _opts), do: []

  def to_list!([_ | _] = list, opts) do
    if Value.list?(list) do
      list
    else
      type_error!(opts, "proper list", list)
    end
  end

  def to_list!(value, opts), do: type_error!(opts, "proper list", value)

  @doc """
  Assert `value` is a Scheme vector and return its elements as an
  Elixir list. The list shape is more idiomatic for Elixir
  iteration; hosts that want a tuple can call `Tuple.to_list/1`'s
  inverse, but most use cases want `Enum`.
  """
  @spec to_vector!(Value.t(), keyword()) :: [Value.t()]
  def to_vector!({:vector, t}, _opts), do: Tuple.to_list(t)
  def to_vector!(value, opts), do: type_error!(opts, "vector", value)

  @doc """
  Assert `value` is a Scheme bytevector and return the underlying
  Elixir binary.
  """
  @spec to_bytevector!(Value.t(), keyword()) :: binary()
  def to_bytevector!({:bytevector, b}, _opts), do: b
  def to_bytevector!(value, opts), do: type_error!(opts, "bytevector", value)

  @doc """
  Assert `value` is a foreign-wrapped host term and return the
  wrapped term. Mirrors `Schooner.Value.foreign_ref/1` but raises
  the host-facing `TypeError` instead of `ArgumentError`.
  """
  @spec to_foreign_ref!(Value.t(), keyword()) :: term()
  def to_foreign_ref!({:foreign, term}, _opts), do: term
  def to_foreign_ref!(value, opts), do: type_error!(opts, "foreign", value)

  @doc """
  Assert `value` is callable from Elixir — a closure, a primitive,
  or a parameter — and return it unchanged. Use this to validate
  the shape of a callback argument before passing it to
  `Schooner.apply/2`.
  """
  @spec to_proc!(Value.t(), keyword()) :: Value.t()
  def to_proc!(value, opts) do
    if Value.procedure?(value) do
      value
    else
      type_error!(opts, "procedure", value)
    end
  end

  # ---------------------------------------------------------------------------
  # Total accessors — to_*/1
  # ---------------------------------------------------------------------------

  @spec to_integer(Value.t()) :: {:ok, integer()} | :error
  def to_integer(value) when is_integer(value), do: {:ok, value}
  def to_integer(_), do: :error

  @spec to_float(Value.t()) :: {:ok, float()} | :error
  def to_float(value) when is_float(value), do: {:ok, value}
  def to_float(_), do: :error

  @spec to_real(Value.t()) :: {:ok, number()} | :error
  def to_real(value) when is_integer(value) or is_float(value), do: {:ok, value}
  def to_real({:rational, n, d}), do: {:ok, n / d}
  def to_real(_), do: :error

  @spec to_string(Value.t()) :: {:ok, binary()} | :error
  def to_string(value) when is_binary(value), do: {:ok, value}
  def to_string(_), do: :error

  @spec to_symbol_name(Value.t()) :: {:ok, binary()} | :error
  def to_symbol_name({:sym, name}), do: {:ok, name}
  def to_symbol_name(_), do: :error

  @spec to_char(Value.t()) :: {:ok, non_neg_integer()} | :error
  def to_char({:char, cp}), do: {:ok, cp}
  def to_char(_), do: :error

  @spec to_bool(Value.t()) :: {:ok, boolean()} | :error
  def to_bool(value) when is_boolean(value), do: {:ok, value}
  def to_bool(_), do: :error

  @spec to_list(Value.t()) :: {:ok, [Value.t()]} | :error
  def to_list([]), do: {:ok, []}

  def to_list([_ | _] = list) do
    if Value.list?(list), do: {:ok, list}, else: :error
  end

  def to_list(_), do: :error

  @spec to_vector(Value.t()) :: {:ok, [Value.t()]} | :error
  def to_vector({:vector, t}), do: {:ok, Tuple.to_list(t)}
  def to_vector(_), do: :error

  @spec to_bytevector(Value.t()) :: {:ok, binary()} | :error
  def to_bytevector({:bytevector, b}), do: {:ok, b}
  def to_bytevector(_), do: :error

  @spec to_foreign_ref(Value.t()) :: {:ok, term()} | :error
  def to_foreign_ref({:foreign, term}), do: {:ok, term}
  def to_foreign_ref(_), do: :error

  @spec to_proc(Value.t()) :: {:ok, Value.t()} | :error
  def to_proc(value) do
    if Value.procedure?(value), do: {:ok, value}, else: :error
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  @spec type_error!(keyword(), binary(), term()) :: no_return()
  defp type_error!(opts, expected, got) do
    op = Keyword.fetch!(opts, :op)
    raise TypeError, op: op, expected: expected, got: got
  end
end
