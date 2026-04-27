defmodule Schooner.ErrorTest do
  use ExUnit.Case, async: true

  alias Schooner.Value

  describe "irritants/1" do
    test "returns the wrapped irritants for an error-object value" do
      e = Schooner.Error.exception(value: Value.error_object(:user, "msg", [1, 2, 3]))
      assert Schooner.Error.irritants(e) == [1, 2, 3]
    end

    test "returns [] for any non error-object value" do
      e = Schooner.Error.exception(value: Value.symbol("oops"))
      assert Schooner.Error.irritants(e) == []
    end
  end

  describe "message formatting" do
    test "error-object with no irritants formats without a colon-list" do
      e = Schooner.Error.exception(value: Value.error_object(:user, "boom", []))
      assert e.message == "uncaught Scheme error: boom"
    end

    test "error-object with irritants joins them after a colon" do
      e = Schooner.Error.exception(value: Value.error_object(:user, "boom", [1, 2]))
      assert e.message == "uncaught Scheme error: boom: 1 2"
    end

    test "non-string message renders via Value.write" do
      # Per Value.error_object's docstring messages should be strings, but
      # the formatter has to defend against malformed values built by hand.
      malformed = {:error_obj, :user, Value.symbol("kaboom"), []}
      e = Schooner.Error.exception(value: malformed)
      assert e.message =~ "kaboom"
    end

    test "raised non-error-object value formats via Value.write" do
      e = Schooner.Error.exception(value: Value.symbol("plain"))
      assert e.message == "uncaught Scheme raise: plain"
    end
  end
end
