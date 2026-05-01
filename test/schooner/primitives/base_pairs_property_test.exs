defmodule Schooner.Primitives.BasePairsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Schooner.Value

  defp small_int_list, do: list_of(integer(-50..50), max_length: 16)

  defp ascii_string,
    do: string([?a..?z, ?A..?Z, ?0..?9], min_length: 0, max_length: 12)

  defp render_int_list(xs), do: "(list " <> Enum.map_join(xs, " ", &Integer.to_string/1) <> ")"

  property "list->vector ∘ vector->list ≡ identity" do
    check all(xs <- small_int_list()) do
      src = render_int_list(xs)

      assert Schooner.run!("(list->vector (vector->list (list->vector #{src})))") ==
               Value.vector(xs)
    end
  end

  property "vector->list ∘ list->vector ≡ identity (on lists)" do
    check all(xs <- small_int_list()) do
      src = render_int_list(xs)
      assert Schooner.run!("(vector->list (list->vector #{src}))") == Value.list(xs)
    end
  end

  property "string->list ∘ list->string ≡ identity (ASCII)" do
    check all(s <- ascii_string()) do
      lit = "\"" <> s <> "\""

      assert Schooner.run!("(list->string (string->list #{lit}))") ==
               Value.string(s)
    end
  end

  property "(length (reverse xs)) == (length xs)" do
    check all(xs <- small_int_list()) do
      src = render_int_list(xs)
      assert Schooner.run!("(length (reverse #{src}))") === length(xs)
    end
  end

  property "(length (map f xs)) == (length xs)" do
    check all(xs <- small_int_list()) do
      src = render_int_list(xs)

      assert Schooner.run!("(length (map (lambda (x) (* x x)) #{src}))") ===
               length(xs)
    end
  end

  property "reverse is its own inverse" do
    check all(xs <- small_int_list()) do
      src = render_int_list(xs)
      assert Schooner.run!("(reverse (reverse #{src}))") == Value.list(xs)
    end
  end
end
