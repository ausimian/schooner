defmodule Schooner.Library.ImportTest do
  use ExUnit.Case, async: true

  alias Schooner.Env
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Library.Import, as: LibImport
  alias Schooner.Library.NotFoundError
  alias Schooner.Library.Standard
  alias Schooner.Reader

  defp datum(source) do
    [d] = Reader.read_string(source)
    d
  end

  defp datums(source), do: Reader.read_string(source)

  defp test_registry do
    Standard.build_registry()
  end

  describe "extract_program_imports/1" do
    test "splits leading imports from the body" do
      forms = datums("(import (scheme base)) (+ 1 2)")
      assert {[spec], [body]} = LibImport.extract_program_imports(forms)
      assert spec == datum("(scheme base)")
      assert body == datum("(+ 1 2)")
    end

    test "concatenates multiple leading import declarations" do
      forms = datums("(import (scheme base)) (import (scheme cxr)) (car '(1))")
      assert {specs, [_body]} = LibImport.extract_program_imports(forms)
      assert specs == [datum("(scheme base)"), datum("(scheme cxr)")]
    end

    test "stops at the first non-import form" do
      forms = datums("(define x 1) (import (scheme base))")
      assert {[], body} = LibImport.extract_program_imports(forms)
      assert length(body) == 2
    end

    test "returns empty imports for an import-free program" do
      forms = datums("(+ 1 2)")
      assert {[], [_]} = LibImport.extract_program_imports(forms)
    end
  end

  describe "resolve/2 — bare library names" do
    test "produces every export of the named library" do
      bindings = LibImport.resolve([datum("(scheme cxr)")], test_registry())
      assert Map.has_key?(bindings, "caar")
      assert Map.has_key?(bindings, "cdddr")
    end

    test "raises NotFoundError on unknown library" do
      assert_raise NotFoundError, fn ->
        LibImport.resolve([datum("(scheme nope)")], test_registry())
      end
    end
  end

  describe "resolve/2 — modifiers" do
    test "(only spec n1 n2 ...) keeps only the named bindings" do
      bindings =
        LibImport.resolve(
          [datum("(only (scheme base) car cdr)")],
          test_registry()
        )

      assert Map.keys(bindings) |> Enum.sort() == ["car", "cdr"]
    end

    test "(except spec n1 n2 ...) drops the named bindings" do
      bindings =
        LibImport.resolve(
          [datum("(except (scheme cxr) caar)")],
          test_registry()
        )

      refute Map.has_key?(bindings, "caar")
      assert Map.has_key?(bindings, "cadr")
    end

    test "(prefix spec p) prepends p to every name" do
      bindings =
        LibImport.resolve(
          [datum("(prefix (only (scheme base) car cdr) my-)")],
          test_registry()
        )

      assert Map.keys(bindings) |> Enum.sort() == ["my-car", "my-cdr"]
    end

    test "(rename spec (old new) ...) renames the listed bindings" do
      bindings =
        LibImport.resolve(
          [datum("(rename (only (scheme base) car cdr) (car head) (cdr tail))")],
          test_registry()
        )

      assert Map.keys(bindings) |> Enum.sort() == ["head", "tail"]
    end

    test "modifiers compose left-to-right outermost-first" do
      bindings =
        LibImport.resolve(
          [datum("(prefix (rename (only (scheme base) car cdr) (car head)) my-)")],
          test_registry()
        )

      assert Map.keys(bindings) |> Enum.sort() == ["my-cdr", "my-head"]
    end
  end

  describe "resolve/2 — multiple specs" do
    test "later specs shadow earlier ones on the same name" do
      bindings =
        LibImport.resolve(
          [
            datum("(only (scheme base) +)"),
            datum("(rename (only (scheme base) car) (car +))")
          ],
          test_registry()
        )

      assert {:var, {:primitive, "car", _, _}} = bindings["+"]
    end
  end

  describe "apply_bindings/3" do
    test "var bindings go into Env" do
      bindings = LibImport.resolve([datum("(only (scheme base) car)")], test_registry())
      {env, _syntax_env} = LibImport.apply_bindings(bindings, Env.new(), SyntaxEnv.new())

      assert match?({:ok, {:primitive, "car", _, _}}, Env.lookup(env, "car"))
    end

    test "macro bindings go into SyntaxEnv" do
      bindings = LibImport.resolve([datum("(only (scheme base) cond)")], test_registry())
      {_env, syntax_env} = LibImport.apply_bindings(bindings, Env.new(), SyntaxEnv.new())

      assert match?({:macro, _}, SyntaxEnv.lookup(syntax_env, "cond"))
    end
  end

  describe "Schooner.eval/2 with imports" do
    test "(import (scheme base)) does not error on a regular program" do
      assert Schooner.run!("(import (scheme base)) (+ 1 2)") == 3
    end

    test "macros remain available after an import (additive on top of bootstrap)" do
      # cond comes from base.scm via the bootstrap env. Adding an import
      # of (scheme base) is additive in 13.4 — the macro stays
      # resolvable. (13.6 will tighten this to "import-or-nothing".)
      assert Schooner.run!("(import (scheme base)) (cond (#t 'yes))") ==
               Schooner.Value.symbol("yes")
    end

    test "renamed import binds the new name" do
      result =
        Schooner.run!("(import (rename (only (scheme base) car) (car head))) (head '(1 2 3))")

      assert result == 1
    end

    test "missing library raises NotFoundError" do
      assert_raise NotFoundError, fn ->
        Schooner.run!("(import (scheme nope)) 1")
      end
    end
  end

  describe "resolve/2 — malformed specs" do
    test "non-list spec is rejected with a clear ArgumentError" do
      err =
        assert_raise ArgumentError, fn ->
          LibImport.resolve([42], test_registry())
        end

      assert err.message =~ "invalid import spec"
    end

    test "rename modifier silently ignores names that aren't in the inner exports" do
      bindings =
        LibImport.resolve(
          [datum("(rename (only (scheme base) car) (cadr nope))")],
          test_registry()
        )

      # `cadr` was never present (we only kept `car`), so the rename is
      # ignored — `car` survives unchanged.
      assert Map.keys(bindings) == ["car"]
    end

    test "rename clause that isn't (old new) is rejected" do
      err =
        assert_raise ArgumentError, fn ->
          LibImport.resolve(
            [datum("(rename (only (scheme base) car) (car))")],
            test_registry()
          )
        end

      assert err.message =~ "invalid rename clause"
    end

    test "non-symbol name in `only` modifier is rejected" do
      err =
        assert_raise ArgumentError, fn ->
          LibImport.resolve(
            [datum(~s|(only (scheme base) "not-a-sym")|)],
            test_registry()
          )
        end

      assert err.message =~ "must be a symbol"
    end
  end
end
