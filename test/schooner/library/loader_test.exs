defmodule Schooner.Library.LoaderTest do
  use ExUnit.Case, async: true

  alias Schooner.Library
  alias Schooner.Library.Loader
  alias Schooner.Library.Standard

  defp standard, do: Standard.build_registry()

  describe "compile/2 — happy path" do
    test "exports a top-level define" do
      source = """
      (define-library (my util)
        (import (scheme base))
        (export square)
        (begin
          (define (square x) (* x x))))
      """

      reg = Loader.load_string(source, standard())
      lib = Library.fetch!(reg, ["my", "util"])

      assert {:var, {:closure, _, _, _, _}} = Map.fetch!(lib.exports, "square")
      assert lib.imports == [["scheme", "base"]]
    end

    test "(rename internal external) renames an exported binding" do
      source = """
      (define-library (m1)
        (import (scheme base))
        (export (rename inner outer))
        (begin (define (inner x) (+ x 1))))
      """

      reg = Loader.load_string(source, standard())
      lib = Library.fetch!(reg, ["m1"])
      assert Map.has_key?(lib.exports, "outer")
      refute Map.has_key?(lib.exports, "inner")
    end

    test "depends on another define-library in the same file" do
      source = """
      (define-library (top)
        (import (utils))
        (export double-square)
        (begin (define (double-square x) (* 2 (sq x)))))
      (define-library (utils)
        (import (scheme base))
        (export sq)
        (begin (define (sq x) (* x x))))
      """

      reg = Loader.load_string(source, standard())
      assert match?({:ok, _}, Library.lookup(reg, ["top"]))
      assert match?({:ok, _}, Library.lookup(reg, ["utils"]))
    end

    test "exporting an undefined binding raises" do
      source = """
      (define-library (broken)
        (import (scheme base))
        (export not-defined)
        (begin (define x 1)))
      """

      assert_raise ArgumentError, ~r/exports not-defined/, fn ->
        Loader.load_string(source, standard())
      end
    end
  end

  describe "topological order" do
    test "cycle between two libraries raises" do
      source = """
      (define-library (a) (import (b)) (export x) (begin (define x 1)))
      (define-library (b) (import (a)) (export y) (begin (define y 2)))
      """

      assert_raise ArgumentError, ~r/cycle in define-library/, fn ->
        Loader.load_string(source, standard())
      end
    end
  end

  describe "cond-expand" do
    test "feature-id selects the matching clause" do
      source = """
      (define-library (cx-feature)
        (cond-expand
          (r7rs (import (scheme base))
                (export who)
                (begin (define who 'r7rs)))
          (else (import (scheme base))
                (export who)
                (begin (define who 'other)))))
      """

      reg = Loader.load_string(source, standard())
      lib = Library.fetch!(reg, ["cx-feature"])
      assert {:var, {:sym, "r7rs"}} = Map.fetch!(lib.exports, "who")
    end

    test "library clause selects when the named library is present" do
      source = """
      (define-library (cx-lib)
        (cond-expand
          ((library (scheme cxr))
            (import (scheme base))
            (export saw-cxr)
            (begin (define saw-cxr #t)))
          (else
            (import (scheme base))
            (export saw-cxr)
            (begin (define saw-cxr #f)))))
      """

      reg = Loader.load_string(source, standard())
      lib = Library.fetch!(reg, ["cx-lib"])
      assert {:var, {:bool, true}} = Map.fetch!(lib.exports, "saw-cxr")
    end

    test "and / or / not requirement combinators" do
      source = """
      (define-library (cx-bool)
        (cond-expand
          ((and r7rs (not (library (scheme nope))))
            (import (scheme base))
            (export ok)
            (begin (define ok 'yes)))
          (else
            (import (scheme base))
            (export ok)
            (begin (define ok 'no)))))
      """

      reg = Loader.load_string(source, standard())
      lib = Library.fetch!(reg, ["cx-bool"])
      assert {:var, {:sym, "yes"}} = Map.fetch!(lib.exports, "ok")
    end

    test "no matching clause produces no declarations" do
      # All clauses fail; library has no body, no imports, no exports.
      source = """
      (define-library (cx-empty)
        (cond-expand
          ((library (scheme nope)) (export x))))
      """

      reg = Loader.load_string(source, standard())
      lib = Library.fetch!(reg, ["cx-empty"])
      assert lib.exports == %{}
    end
  end

  describe "deferred declarations" do
    test "(include ...) raises a clear 'not yet supported' error" do
      source = """
      (define-library (with-include)
        (include "missing.scm"))
      """

      assert_raise ArgumentError, ~r/include.*not yet supported/, fn ->
        Loader.load_string(source, standard())
      end
    end
  end

  describe "load_file/2" do
    @tag :tmp_dir
    test "loads define-library declarations from disk", %{tmp_dir: dir} do
      path = Path.join(dir, "lib.scm")

      File.write!(path, """
      (define-library (from-file)
        (import (scheme base))
        (export forty-two)
        (begin (define forty-two 42)))
      """)

      reg = Loader.load_file(path, standard())
      lib = Library.fetch!(reg, ["from-file"])
      assert {:var, 42} = Map.fetch!(lib.exports, "forty-two")
    end
  end
end
