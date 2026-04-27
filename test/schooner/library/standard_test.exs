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

  test "build_registry/0 returns an empty registry in the 13.1 skeleton" do
    assert Standard.build_registry() == %{}
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
    # `Schooner.Application.start/2` calls `Standard.boot/0` before any
    # test runs, so the persistent-term key is populated for every
    # process in the VM. This pins that contract — if someone removes
    # the boot wiring, this test fails.
    {:ok, _apps_started} = Application.ensure_all_started(:schooner)
    refute :persistent_term.get({Library, :standard}, :unset) == :unset
  end
end
