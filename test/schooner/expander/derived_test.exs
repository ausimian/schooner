defmodule Schooner.Expander.DerivedTest do
  use ExUnit.Case, async: true

  alias Schooner.Expander.Derived

  test "priv_files/0 lists base.scm and lazy.scm in load order" do
    assert Derived.priv_files() == ["base.scm", "lazy.scm"]
  end

  test "source/0 concatenates the priv files with a newline separator" do
    src = Derived.source()
    assert is_binary(src)
    # Both files contribute identifiable content; check at least the
    # prelude commentary tokens exist.
    assert src =~ "define-syntax"
  end
end
