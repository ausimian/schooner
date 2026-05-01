defmodule Schooner.HostTest do
  use ExUnit.Case, async: true

  alias Schooner.Host
  alias Schooner.Host.TypeError
  alias Schooner.Value

  describe "constructors" do
    test "bool/1 produces Scheme booleans" do
      assert Host.bool(true) === true
      assert Host.bool(false) === false
    end

    test "string/1 produces a Scheme string" do
      assert Host.string("hello") === "hello"
    end

    test "symbol/1 produces a Scheme symbol" do
      assert Host.symbol("foo") === {:sym, "foo"}
    end

    test "char/1 produces a Scheme character" do
      assert Host.char(?a) === {:char, ?a}
    end

    test "pair/2 produces a Scheme pair" do
      assert Host.pair(1, 2) === [1 | 2]
      assert Host.pair(1, []) === [1]
    end

    test "list/1 produces a proper Scheme list" do
      assert Host.list([1, 2, 3]) === [1, 2, 3]
      assert Host.list([]) === []
    end

    test "vector/1 produces a Scheme vector" do
      assert Host.vector([1, 2, 3]) === {:vector, {1, 2, 3}}
    end

    test "bytevector/1 accepts a list of bytes or a binary" do
      assert Host.bytevector([1, 2, 3]) === {:bytevector, <<1, 2, 3>>}
      assert Host.bytevector(<<4, 5>>) === {:bytevector, <<4, 5>>}
    end

    test "foreign/1 wraps an arbitrary host term" do
      pid = self()
      assert Host.foreign(pid) === {:foreign, pid}
    end

    test "primitive/3 builds a primitive value" do
      fun = fn [x] -> x end
      assert {:primitive, "id", 1, ^fun} = Host.primitive("id", 1, fun)
    end
  end

  describe "to_integer!/2" do
    test "returns the integer for a bare exact integer" do
      assert Host.to_integer!(42, op: "t") === 42
      assert Host.to_integer!(-1, op: "t") === -1
      assert Host.to_integer!(0, op: "t") === 0
    end

    test "raises on non-integer values with op + expected populated" do
      assert_raise TypeError, fn -> Host.to_integer!(1.0, op: "t") end
      assert_raise TypeError, fn -> Host.to_integer!({:rational, 1, 2}, op: "t") end
      assert_raise TypeError, fn -> Host.to_integer!("42", op: "t") end
      assert_raise TypeError, fn -> Host.to_integer!({:sym, "n"}, op: "t") end
    end

    test "TypeError carries op, expected, and got" do
      err =
        try do
          Host.to_integer!(1.5, op: "myapp/count")
          flunk("should have raised")
        rescue
          e in TypeError -> e
        end

      assert err.op === "myapp/count"
      assert err.expected === "integer"
      assert err.got === 1.5
      assert err.message =~ "myapp/count"
      assert err.message =~ "integer"
    end
  end

  describe "to_float!/2" do
    test "returns the bare float" do
      assert Host.to_float!(1.5, op: "t") === 1.5
      assert Host.to_float!(0.0, op: "t") === 0.0
    end

    test "rejects integers (host should call to_real! for coercion)" do
      assert_raise TypeError, fn -> Host.to_float!(1, op: "t") end
    end

    test "rejects float specials and non-numbers" do
      assert_raise TypeError, fn -> Host.to_float!({:float_special, :pos_inf}, op: "t") end
      assert_raise TypeError, fn -> Host.to_float!("1.0", op: "t") end
    end
  end

  describe "to_real!/2" do
    test "passes through integers and floats" do
      assert Host.to_real!(42, op: "t") === 42
      assert Host.to_real!(1.5, op: "t") === 1.5
    end

    test "coerces rationals to floats" do
      assert Host.to_real!({:rational, 1, 2}, op: "t") === 0.5
    end

    test "rejects float specials and complex" do
      assert_raise TypeError, fn -> Host.to_real!({:float_special, :nan}, op: "t") end
      assert_raise TypeError, fn -> Host.to_real!({:complex, 1, 1}, op: "t") end
      assert_raise TypeError, fn -> Host.to_real!("1", op: "t") end
    end
  end

  describe "to_string!/2" do
    test "returns the underlying binary" do
      assert Host.to_string!("hello", op: "t") === "hello"
      assert Host.to_string!("", op: "t") === ""
    end

    test "rejects symbols, bytevectors, and non-strings" do
      assert_raise TypeError, fn -> Host.to_string!({:sym, "foo"}, op: "t") end
      assert_raise TypeError, fn -> Host.to_string!({:bytevector, <<1>>}, op: "t") end
      assert_raise TypeError, fn -> Host.to_string!(42, op: "t") end
    end
  end

  describe "to_symbol_name!/2" do
    test "extracts the binary name from a symbol" do
      assert Host.to_symbol_name!({:sym, "foo"}, op: "t") === "foo"
    end

    test "rejects strings and non-symbols" do
      assert_raise TypeError, fn -> Host.to_symbol_name!("foo", op: "t") end
      assert_raise TypeError, fn -> Host.to_symbol_name!(42, op: "t") end
    end
  end

  describe "to_char!/2" do
    test "extracts the codepoint" do
      assert Host.to_char!({:char, ?a}, op: "t") === ?a
      assert Host.to_char!({:char, 0x1F600}, op: "t") === 0x1F600
    end

    test "rejects integers and non-chars" do
      assert_raise TypeError, fn -> Host.to_char!(?a, op: "t") end
      assert_raise TypeError, fn -> Host.to_char!("a", op: "t") end
    end
  end

  describe "to_bool!/2" do
    test "returns true / false for booleans" do
      assert Host.to_bool!(true, op: "t") === true
      assert Host.to_bool!(false, op: "t") === false
    end

    test "rejects truthy non-booleans" do
      assert_raise TypeError, fn -> Host.to_bool!(0, op: "t") end
      assert_raise TypeError, fn -> Host.to_bool!([], op: "t") end
      assert_raise TypeError, fn -> Host.to_bool!("true", op: "t") end
    end
  end

  describe "to_list!/2" do
    test "accepts the empty list" do
      assert Host.to_list!([], op: "t") === []
    end

    test "accepts proper Scheme lists" do
      assert Host.to_list!([1, 2, 3], op: "t") === [1, 2, 3]
      assert Host.to_list!([Value.string("a")], op: "t") === ["a"]
    end

    test "rejects improper lists" do
      assert_raise TypeError, fn -> Host.to_list!([1, 2 | 3], op: "t") end
      assert_raise TypeError, fn -> Host.to_list!(Value.improper_list([1, 2], 3), op: "t") end
    end

    test "rejects non-list atoms" do
      assert_raise TypeError, fn -> Host.to_list!(42, op: "t") end
      assert_raise TypeError, fn -> Host.to_list!({:sym, "foo"}, op: "t") end
    end
  end

  describe "to_vector!/2" do
    test "returns the elements as an Elixir list" do
      assert Host.to_vector!({:vector, {1, 2, 3}}, op: "t") === [1, 2, 3]
      assert Host.to_vector!({:vector, {}}, op: "t") === []
    end

    test "rejects non-vectors" do
      assert_raise TypeError, fn -> Host.to_vector!([1, 2, 3], op: "t") end
      assert_raise TypeError, fn -> Host.to_vector!(42, op: "t") end
    end
  end

  describe "to_bytevector!/2" do
    test "returns the underlying binary" do
      assert Host.to_bytevector!({:bytevector, <<1, 2, 3>>}, op: "t") === <<1, 2, 3>>
    end

    test "rejects strings and non-bytevectors" do
      assert_raise TypeError, fn -> Host.to_bytevector!("abc", op: "t") end
      assert_raise TypeError, fn -> Host.to_bytevector!({:vector, {1, 2}}, op: "t") end
    end
  end

  describe "to_foreign_ref!/2" do
    test "unwraps a foreign payload" do
      pid = self()
      assert Host.to_foreign_ref!({:foreign, pid}, op: "t") === pid
      assert Host.to_foreign_ref!({:foreign, %{a: 1}}, op: "t") === %{a: 1}
    end

    test "rejects non-foreign values" do
      assert_raise TypeError, fn -> Host.to_foreign_ref!(42, op: "t") end
      assert_raise TypeError, fn -> Host.to_foreign_ref!({:sym, "foo"}, op: "t") end
    end
  end

  describe "to_proc!/2" do
    test "accepts closures, primitives, and parameters" do
      closure = Value.closure({:fixed, 0, []}, [], :no_env, nil)
      primitive = Value.primitive("id", 1, fn [x] -> x end)
      parameter = Value.parameter(0, nil)

      assert Host.to_proc!(closure, op: "t") === closure
      assert Host.to_proc!(primitive, op: "t") === primitive
      assert Host.to_proc!(parameter, op: "t") === parameter
    end

    test "rejects non-procedures" do
      assert_raise TypeError, fn -> Host.to_proc!(42, op: "t") end
      assert_raise TypeError, fn -> Host.to_proc!({:sym, "foo"}, op: "t") end
    end
  end

  describe "total accessors return {:ok, _} | :error" do
    test "to_integer/1" do
      assert Host.to_integer(42) === {:ok, 42}
      assert Host.to_integer(1.0) === :error
    end

    test "to_float/1" do
      assert Host.to_float(1.5) === {:ok, 1.5}
      assert Host.to_float(1) === :error
    end

    test "to_real/1" do
      assert Host.to_real(2) === {:ok, 2}
      assert Host.to_real(1.5) === {:ok, 1.5}
      assert Host.to_real({:rational, 1, 4}) === {:ok, 0.25}
      assert Host.to_real({:float_special, :nan}) === :error
    end

    test "to_string/1" do
      assert Host.to_string("hi") === {:ok, "hi"}
      assert Host.to_string({:sym, "hi"}) === :error
    end

    test "to_symbol_name/1" do
      assert Host.to_symbol_name({:sym, "hi"}) === {:ok, "hi"}
      assert Host.to_symbol_name("hi") === :error
    end

    test "to_char/1" do
      assert Host.to_char({:char, ?z}) === {:ok, ?z}
      assert Host.to_char(?z) === :error
    end

    test "to_bool/1" do
      assert Host.to_bool(true) === {:ok, true}
      assert Host.to_bool(false) === {:ok, false}
      assert Host.to_bool([]) === :error
    end

    test "to_list/1" do
      assert Host.to_list([]) === {:ok, []}
      assert Host.to_list([1, 2, 3]) === {:ok, [1, 2, 3]}
      assert Host.to_list([1 | 2]) === :error
      assert Host.to_list(42) === :error
    end

    test "to_vector/1" do
      assert Host.to_vector({:vector, {1, 2}}) === {:ok, [1, 2]}
      assert Host.to_vector(42) === :error
    end

    test "to_bytevector/1" do
      assert Host.to_bytevector({:bytevector, <<1>>}) === {:ok, <<1>>}
      assert Host.to_bytevector("a") === :error
    end

    test "to_foreign_ref/1" do
      assert Host.to_foreign_ref({:foreign, :payload}) === {:ok, :payload}
      assert Host.to_foreign_ref(42) === :error
    end

    test "to_proc/1" do
      primitive = Value.primitive("id", 1, fn [x] -> x end)
      assert Host.to_proc(primitive) === {:ok, primitive}
      assert Host.to_proc(42) === :error
    end
  end

  describe "TypeError shape" do
    test "exception/1 builds the message from op + expected + got" do
      err = TypeError.exception(op: "lib/foo", expected: "string", got: 42)
      assert err.op === "lib/foo"
      assert err.expected === "string"
      assert err.got === 42
      assert err.message === "host conversion in `lib/foo`: expected string, got 42"
    end
  end
end
