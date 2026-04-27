defmodule Schooner.Library.StandardTest do
  # async: false — these tests touch the global persistent term
  # `{Schooner.Library, :standard}`. We snapshot/restore so a parallel
  # suite would still see a consistent view, but keeping this file
  # serial is the simpler guarantee.
  use ExUnit.Case, async: false

  alias Schooner.Library
  alias Schooner.Library.Standard

  setup do
    snapshot = :persistent_term.get({Library, :standard}, %{})

    on_exit(fn ->
      :persistent_term.put({Library, :standard}, snapshot)
    end)

    :ok
  end

  test "build_registry/0 produces all standard libraries" do
    registry = Standard.build_registry()

    expected_names = [
      ["scheme", "base"],
      ["scheme", "cxr"],
      ["scheme", "char"],
      ["scheme", "inexact"],
      ["scheme", "write"],
      ["scheme", "read"],
      ["scheme", "case-lambda"],
      ["scheme", "lazy"]
    ]

    for name <- expected_names do
      assert {:ok, _lib} = Library.lookup(registry, name),
             "expected library #{Library.render_name(name)} in standard registry"
    end
  end

  test "every standard library declares the :r7rs feature" do
    registry = Standard.build_registry()

    for {_name, lib} <- registry do
      assert :r7rs in lib.features
    end
  end

  test "(scheme base) exports the unioned primitives" do
    %{exports: exports} =
      Library.fetch!(Standard.build_registry(), ["scheme", "base"])

    # spot-check one binding from each contributing module
    assert match?({:var, _}, Map.fetch!(exports, "+")), "from Primitives.Base"
    # `make-record-instance` etc. live behind generated names; check a stable one
    assert match?({:var, _}, Map.fetch!(exports, "raise")), "from Primitives.Exceptions"
    assert match?({:var, _}, Map.fetch!(exports, "call/cc")), "from Primitives.Continuations"
  end

  test "(scheme inexact) exports every r7rs name" do
    %{exports: exports} =
      Library.fetch!(Standard.build_registry(), ["scheme", "inexact"])

    expected = ~w(exp log sin cos tan asin acos atan finite? infinite? nan?)
    assert Enum.sort(Map.keys(exports)) == Enum.sort(expected)
  end

  test "(scheme write) exports the four write procedures" do
    %{exports: exports} =
      Library.fetch!(Standard.build_registry(), ["scheme", "write"])

    expected = ~w(write display write-shared write-simple)
    assert Enum.sort(Map.keys(exports)) == Enum.sort(expected)
  end

  test "(scheme read) exports read" do
    %{exports: exports} =
      Library.fetch!(Standard.build_registry(), ["scheme", "read"])

    assert Map.keys(exports) == ["read"]
  end

  test "(scheme case-lambda) is a stub pending its macro implementation" do
    %{exports: exports} =
      Library.fetch!(Standard.build_registry(), ["scheme", "case-lambda"])

    assert exports == %{}
  end

  test "(scheme lazy) exports primitives plus delay/delay-force macros" do
    %{exports: exports} = Library.fetch!(Standard.build_registry(), ["scheme", "lazy"])

    assert match?({:var, _}, Map.fetch!(exports, "make-promise"))
    assert match?({:var, _}, Map.fetch!(exports, "force"))
    assert match?({:var, _}, Map.fetch!(exports, "promise?"))
    assert match?({:macro, _}, Map.fetch!(exports, "delay"))
    assert match?({:macro, _}, Map.fetch!(exports, "delay-force"))
  end

  test "(scheme base) exports the derived-form macros from base.scm" do
    %{exports: exports} = Library.fetch!(Standard.build_registry(), ["scheme", "base"])

    for name <- ~w(when unless and or let let* letrec cond case do) do
      assert match?({:macro, _}, Map.fetch!(exports, name)),
             "expected (scheme base) to export macro #{name}"
    end
  end

  test "boot/0 stores the registry under the canonical persistent term key" do
    assert Standard.boot() == :ok
    assert Library.standard() == Standard.build_registry()
  end

  test "Library.standard/0 is visible from a freshly spawned process" do
    Standard.boot()
    parent = self()

    spawn(fn ->
      send(parent, {:from_child, Library.standard()})
    end)

    assert_receive {:from_child, registry}
    assert registry == Standard.build_registry()
  end

  test "the OTP application has already booted the registry" do
    {:ok, _apps_started} = Application.ensure_all_started(:schooner)
    refute :persistent_term.get({Library, :standard}, :unset) == :unset
  end
end
