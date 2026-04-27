defmodule Schooner.Eval.ContinuationStateTest do
  use ExUnit.Case, async: false

  alias Schooner.Eval.ContinuationState

  setup do
    on_exit(fn -> ContinuationState.reset() end)
    ContinuationState.reset()
    :ok
  end

  test "register / live? / deregister round-trip" do
    tag = make_ref()

    refute ContinuationState.live?(tag)
    ContinuationState.register(tag)
    assert ContinuationState.live?(tag)
    ContinuationState.deregister(tag)
    refute ContinuationState.live?(tag)
  end

  test "snapshot and restore preserve the live-tag set" do
    a = make_ref()
    b = make_ref()
    ContinuationState.register(a)
    ContinuationState.register(b)

    snapshot = ContinuationState.snapshot()
    assert MapSet.size(snapshot) == 2

    ContinuationState.reset()
    refute ContinuationState.live?(a)
    refute ContinuationState.live?(b)

    ContinuationState.restore(snapshot)
    assert ContinuationState.live?(a)
    assert ContinuationState.live?(b)
  end

  test "restore of an empty snapshot clears the slot" do
    ContinuationState.register(make_ref())
    ContinuationState.restore(MapSet.new())
    assert ContinuationState.snapshot() == MapSet.new()
  end

  test "deregister of the last tag clears the slot" do
    tag = make_ref()
    ContinuationState.register(tag)
    ContinuationState.deregister(tag)

    # The set is now empty — confirmed by re-checking via snapshot, which
    # surfaces an empty MapSet whether the slot is gone or holds an empty
    # set (the implementation chooses the former).
    assert ContinuationState.snapshot() == MapSet.new()
  end
end
