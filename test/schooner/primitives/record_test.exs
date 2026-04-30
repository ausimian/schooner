defmodule Schooner.Primitives.RecordTest do
  # Phase 10 — direct tests for the record-machinery primitives that
  # `define-record-type` lowers to. These pin behaviour at the
  # primitive boundary regardless of what shape the expander emits.
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Library
  alias Schooner.Library.Import, as: LibImport
  alias Schooner.Primitive.Error, as: PError
  alias Schooner.Value

  # `(scheme base)` includes both Primitives.Base and the
  # Primitives.Record machinery (`%record-instance`, `%record-of?`,
  # `%record-ref`), so a single import covers what these tests need.
  defp env do
    base = Library.fetch!(Library.standard(), ["scheme", "base"]).exports
    {env, _} = LibImport.apply_bindings(base, Env.new(), SyntaxEnv.new())
    env
  end

  defp run(source, env), do: Schooner.eval(source, env)

  test "%record-instance constructs a record value with the given type id and fields" do
    env = env()
    type_id = {:record_type, "tag", :erlang.unique_integer([:positive])}

    Env.define(env, "type-id", type_id)

    assert run("(%record-instance type-id 1 2 3)", env) ==
             Value.record(type_id, {1, 2, 3})
  end

  test "%record-instance with no fields builds a zero-field record" do
    env = env()
    type_id = {:record_type, "tag", :erlang.unique_integer([:positive])}

    Env.define(env, "type-id", type_id)

    assert run("(%record-instance type-id)", env) == Value.record(type_id, {})
  end

  test "%record-of? returns #t only when the type ids are eqv?" do
    env = env()
    id1 = {:record_type, "a", 1}
    id2 = {:record_type, "a", 2}

    Env.define(env, "id1", id1)
    Env.define(env, "id2", id2)

    assert run("(%record-of? id1 (%record-instance id1 0))", env) == Value.bool(true)
    assert run("(%record-of? id2 (%record-instance id1 0))", env) == Value.bool(false)
    assert run("(%record-of? id1 'not-a-record)", env) == Value.bool(false)
    assert run("(%record-of? id1 #(0 1 2))", env) == Value.bool(false)
  end

  test "%record-ref returns the indexed field of a matching record" do
    env = env()
    id = {:record_type, "tag", 1}

    Env.define(env, "id", id)

    assert run("(%record-ref id (%record-instance id 'a 'b 'c) 0)", env) == Value.symbol("a")
    assert run("(%record-ref id (%record-instance id 'a 'b 'c) 2)", env) == Value.symbol("c")
  end

  test "%record-ref raises Schooner.Primitive.Error on a wrong-type value" do
    env = env()
    id1 = {:record_type, "a", 1}
    id2 = {:record_type, "a", 2}

    Env.define(env, "id1", id1)
    Env.define(env, "id2", id2)

    assert_raise PError, fn ->
      run("(%record-ref id1 (%record-instance id2 0) 0)", env)
    end

    assert_raise PError, fn ->
      run("(%record-ref id1 'not-a-record 0)", env)
    end
  end

  test "%record-ref raises with an inspected name when the type-id isn't a record-type tuple" do
    # `%record-instance` accepts any first argument as a type id, so it's
    # possible to construct a record whose id is a bare symbol. The error
    # path falls through to `inspect/1` for the type name.
    env = env()
    real = {:record_type, "real", 1}
    Env.define(env, "real", real)

    e =
      assert_raise PError, fn ->
        run("(%record-ref 'junk (%record-instance real 0) 0)", env)
      end

    assert match?({:wrong_record_type, "%record-ref", _}, e.reason)
  end
end
