defmodule Schooner.LibraryTest do
  use ExUnit.Case, async: true

  alias Schooner.Library
  alias Schooner.Library.NotFoundError

  describe "new/1" do
    test "requires :name" do
      assert_raise KeyError, fn -> Library.new([]) end
    end

    test "accepts binary segments" do
      lib = Library.new(name: ["scheme", "base"])
      assert lib.name == ["scheme", "base"]
      assert lib.exports == %{}
      assert lib.imports == []
      assert lib.source == :native
      assert lib.features == []
    end

    test "accepts non-negative integer segments" do
      lib = Library.new(name: ["srfi", 1])
      assert lib.name == ["srfi", 1]
    end

    test "rejects atom segments" do
      assert_raise ArgumentError, ~r/segment must be a binary or non-negative integer/, fn ->
        Library.new(name: [:scheme, :base])
      end
    end

    test "rejects empty name" do
      assert_raise ArgumentError, ~r/non-empty list/, fn -> Library.new(name: []) end
    end

    test "rejects non-list name" do
      assert_raise ArgumentError, ~r/non-empty list/, fn -> Library.new(name: "scheme.base") end
    end

    test "rejects negative integer segment" do
      assert_raise ArgumentError, ~r/binary or non-negative integer/, fn ->
        Library.new(name: ["srfi", -1])
      end
    end

    test "validates exports map shape" do
      assert_raise ArgumentError, ~r/library export must be/, fn ->
        Library.new(name: ["x"], exports: %{"foo" => :raw_value})
      end

      assert_raise ArgumentError, ~r/library export must be/, fn ->
        Library.new(name: ["x"], exports: %{:foo => {:var, 1}})
      end

      assert_raise ArgumentError, ~r/library exports must be a map/, fn ->
        Library.new(name: ["x"], exports: [{"foo", {:var, 1}}])
      end
    end

    test "accepts var and macro export tags" do
      lib =
        Library.new(
          name: ["x"],
          exports: %{
            "v" => {:var, 42},
            "m" => {:macro, :transformer_term}
          }
        )

      assert lib.exports["v"] == {:var, 42}
      assert lib.exports["m"] == {:macro, :transformer_term}
    end

    test "validates each import name" do
      assert_raise ArgumentError, ~r/non-empty list/, fn ->
        Library.new(name: ["x"], imports: [["scheme", "base"], "not-a-list"])
      end
    end

    test "validates :source" do
      assert_raise ArgumentError, ~r/:source must be/, fn ->
        Library.new(name: ["x"], source: :file)
      end

      lib = Library.new(name: ["x"], source: {:file, "priv/scheme/base.scm", {1, 1}})
      assert lib.source == {:file, "priv/scheme/base.scm", {1, 1}}
    end

    test "validates :features" do
      assert_raise ArgumentError, ~r/:features must be a list of atoms/, fn ->
        Library.new(name: ["x"], features: %{})
      end

      assert_raise ArgumentError, ~r/feature must be an atom/, fn ->
        Library.new(name: ["x"], features: ["r7rs"])
      end

      lib = Library.new(name: ["x"], features: [:r7rs])
      assert lib.features == [:r7rs]
    end
  end

  describe "register/2 + lookup/2" do
    test "round-trips a single library" do
      lib = Library.new(name: ["scheme", "base"])
      registry = Library.register(%{}, lib)
      assert Library.lookup(registry, ["scheme", "base"]) == {:ok, lib}
    end

    test "lookup miss returns :error" do
      assert Library.lookup(%{}, ["scheme", "base"]) == :error
    end

    test "register raises on duplicate canonical name" do
      lib = Library.new(name: ["scheme", "base"])
      registry = Library.register(%{}, lib)

      assert_raise ArgumentError, ~r/already registered/, fn ->
        Library.register(registry, lib)
      end
    end

    test "names with different segment shapes do not collide" do
      a = Library.new(name: ["srfi", 1])
      b = Library.new(name: ["srfi", "1"])
      registry = %{} |> Library.register(a) |> Library.register(b)
      assert Library.lookup(registry, ["srfi", 1]) == {:ok, a}
      assert Library.lookup(registry, ["srfi", "1"]) == {:ok, b}
    end
  end

  describe "fetch!/2" do
    test "returns the library when present" do
      lib = Library.new(name: ["x"])
      registry = Library.register(%{}, lib)
      assert Library.fetch!(registry, ["x"]) == lib
    end

    test "raises NotFoundError with a formatted message on miss" do
      err = assert_raise NotFoundError, fn -> Library.fetch!(%{}, ["scheme", "inexact"]) end
      assert Exception.message(err) == "library not found: (scheme inexact)"
    end
  end

  describe "render_name/1" do
    test "formats a binary-segment name" do
      assert Library.render_name(["scheme", "base"]) == "(scheme base)"
    end

    test "formats integer segments" do
      assert Library.render_name(["srfi", 1]) == "(srfi 1)"
    end
  end

  describe "topo_sort/1" do
    test "orders imports before importers" do
      base = Library.new(name: ["scheme", "base"])
      char = Library.new(name: ["scheme", "char"], imports: [["scheme", "base"]])

      registry = %{} |> Library.register(base) |> Library.register(char)
      assert {:ok, order} = Library.topo_sort(registry)

      assert Enum.find_index(order, &(&1 == ["scheme", "base"])) <
               Enum.find_index(order, &(&1 == ["scheme", "char"]))
    end

    test "skips edges to libraries not present in the registry" do
      lib = Library.new(name: ["x"], imports: [["not-yet-registered"]])
      registry = Library.register(%{}, lib)
      assert {:ok, [["x"]]} = Library.topo_sort(registry)
    end

    test "detects a 2-cycle" do
      a = Library.new(name: ["a"], imports: [["b"]])
      b = Library.new(name: ["b"], imports: [["a"]])
      registry = %{} |> Library.register(a) |> Library.register(b)

      assert {:error, {:cycle, cycle}} = Library.topo_sort(registry)
      assert hd(cycle) == List.last(cycle)
      assert Enum.sort(Enum.uniq(cycle)) == [["a"], ["b"]]
    end

    test "detects a 3-cycle" do
      a = Library.new(name: ["a"], imports: [["b"]])
      b = Library.new(name: ["b"], imports: [["c"]])
      c = Library.new(name: ["c"], imports: [["a"]])
      registry = %{} |> Library.register(a) |> Library.register(b) |> Library.register(c)

      assert {:error, {:cycle, cycle}} = Library.topo_sort(registry)
      assert hd(cycle) == List.last(cycle)
      assert Enum.sort(Enum.uniq(cycle)) == [["a"], ["b"], ["c"]]
    end

    test "diamond dependencies sort cleanly" do
      base = Library.new(name: ["base"])
      l = Library.new(name: ["l"], imports: [["base"]])
      r = Library.new(name: ["r"], imports: [["base"]])
      top = Library.new(name: ["top"], imports: [["l"], ["r"]])

      registry =
        %{}
        |> Library.register(base)
        |> Library.register(l)
        |> Library.register(r)
        |> Library.register(top)

      assert {:ok, order} = Library.topo_sort(registry)
      idx = fn name -> Enum.find_index(order, &(&1 == name)) end
      assert idx.(["base"]) < idx.(["l"])
      assert idx.(["base"]) < idx.(["r"])
      assert idx.(["l"]) < idx.(["top"])
      assert idx.(["r"]) < idx.(["top"])
    end
  end
end
