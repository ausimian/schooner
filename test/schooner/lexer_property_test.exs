defmodule Schooner.LexerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Schooner.Lexer

  property "integers round-trip through the lexer" do
    check all(n <- integer()) do
      src = Integer.to_string(n)
      assert [{:integer, ^n, {1, 1}}] = Lexer.tokenise(src)
    end
  end

  property "plain identifiers round-trip" do
    check all(name <- plain_identifier()) do
      assert [{:ident, ^name, {1, 1}}] = Lexer.tokenise(name)
    end
  end

  property "decimal floats round-trip when re-emitted via short form" do
    check all(f <- bounded_float()) do
      src = :erlang.float_to_binary(f, [:short])

      case Lexer.tokenise(src) do
        [{:float, parsed, {1, 1}}] -> assert parsed == f
      end
    end
  end

  defp plain_identifier do
    initial =
      one_of([
        member_of(?a..?z |> Enum.to_list()),
        member_of(?A..?Z |> Enum.to_list())
      ])

    subseq =
      one_of([
        member_of(?a..?z |> Enum.to_list()),
        member_of(?A..?Z |> Enum.to_list()),
        member_of(?0..?9 |> Enum.to_list()),
        member_of(~c"-_!?")
      ])

    bind(initial, fn first ->
      bind(list_of(subseq, max_length: 8), fn rest ->
        constant(IO.iodata_to_binary([first | rest]))
      end)
    end)
  end

  defp bounded_float do
    map(integer(-1_000_000..1_000_000), fn n -> n / 1.0 end)
  end
end
