defmodule Schooner.EnvTest do
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Value

  test "new/0 returns an env with no lexical frames" do
    env = Env.new()
    assert env.lex == []
    assert is_reference(env.globals) or is_integer(env.globals)
  end

  test "lookup of an unbound name returns :error" do
    assert Env.lookup(Env.new(), "nope") == :error
  end

  test "define/3 + lookup roundtrip on globals" do
    env = Env.new() |> Env.define("x", 1) |> Env.define("y", Value.symbol("y"))
    assert Env.lookup(env, "x") == {:ok, 1}
    assert Env.lookup(env, "y") == {:ok, Value.symbol("y")}
  end

  test "define/3 overwrites a previous global binding" do
    env = Env.new() |> Env.define("x", 1) |> Env.define("x", 2)
    assert Env.lookup(env, "x") == {:ok, 2}
  end

  test "extend/2 pushes a lexical frame; lookup walks innermost-first" do
    env =
      Env.new()
      |> Env.define("x", :outer_global)
      |> Env.extend([{"x", :outer_lex}])
      |> Env.extend([{"x", :inner_lex}])

    assert Env.lookup(env, "x") == {:ok, :inner_lex}
  end

  test "lex frame falls through to global when name is absent locally" do
    env =
      Env.new()
      |> Env.define("g", 99)
      |> Env.extend([{"local", 1}])

    assert Env.lookup(env, "g") == {:ok, 99}
    assert Env.lookup(env, "local") == {:ok, 1}
  end

  test "global define is visible through previously-pushed lex frames" do
    base = Env.new() |> Env.extend([{"a", 1}])
    Env.define(base, "later", 42)
    assert Env.lookup(base, "later") == {:ok, 42}
  end

  test "two envs created independently do not share globals" do
    a = Env.new() |> Env.define("k", 1)
    b = Env.new()
    assert Env.lookup(a, "k") == {:ok, 1}
    assert Env.lookup(b, "k") == :error
  end

  test "pop/1 removes the topmost lexical frame" do
    env =
      Env.new()
      |> Env.define("g", :global)
      |> Env.extend([{"x", :outer}])
      |> Env.extend([{"x", :inner}])

    assert Env.lookup(env, "x") == {:ok, :inner}

    after_one_pop = Env.pop(env)
    assert Env.lookup(after_one_pop, "x") == {:ok, :outer}

    after_two_pops = Env.pop(after_one_pop)
    assert Env.lookup(after_two_pops, "x") == :error
    assert Env.lookup(after_two_pops, "g") == {:ok, :global}
  end
end
