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

    @tag :tmp_dir
    test "populates :source with {:file, path, span}", %{tmp_dir: dir} do
      path = Path.join(dir, "lib.scm")

      File.write!(path, """

      (define-library (from-file)
        (import (scheme base))
        (export forty-two)
        (begin (define forty-two 42)))
      """)

      reg = Loader.load_file(path, standard())
      lib = Library.fetch!(reg, ["from-file"])
      assert {:file, ^path, {2, 1}} = lib.source
    end
  end

  describe "diagnostics quote source positions" do
    @tag :tmp_dir
    test "unsupported declaration head includes path:line:col", %{tmp_dir: dir} do
      path = Path.join(dir, "bad.scm")

      File.write!(path, """
      (define-library (broken)
        (import (scheme base))
        (nope something))
      """)

      assert_raise ArgumentError, ~r/#{Regex.escape(path)}:3:3/, fn ->
        Loader.load_file(path, standard())
      end
    end

    @tag :tmp_dir
    test "exporting an undefined binding includes path and line", %{tmp_dir: dir} do
      path = Path.join(dir, "bad-export.scm")

      File.write!(path, """
      (define-library (broken)
        (import (scheme base))
        (export not-defined)
        (begin (define x 1)))
      """)

      assert_raise ArgumentError, ~r/#{Regex.escape(path)}:3:11.*not-defined/s, fn ->
        Loader.load_file(path, standard())
      end
    end

    @tag :tmp_dir
    test "invalid cond-expand requirement includes file:line", %{tmp_dir: dir} do
      path = Path.join(dir, "bad-cx.scm")

      File.write!(path, """
      (define-library (cx-bad)
        (cond-expand
          (123 (export nope))))
      """)

      assert_raise ArgumentError, ~r/#{Regex.escape(path)}:3:6.*invalid cond-expand/s, fn ->
        Loader.load_file(path, standard())
      end
    end

    @tag :tmp_dir
    test "invalid export entry includes file:line", %{tmp_dir: dir} do
      path = Path.join(dir, "bad-entry.scm")

      File.write!(path, """
      (define-library (e-bad)
        (import (scheme base))
        (export (rename only-one)))
      """)

      assert_raise ArgumentError, ~r/#{Regex.escape(path)}:3:11.*invalid export entry/s, fn ->
        Loader.load_file(path, standard())
      end
    end

    @tag :tmp_dir
    test "cycle error names every cycle participant with its position", %{tmp_dir: dir} do
      path = Path.join(dir, "cycle.scm")

      File.write!(path, """
      (define-library (a) (import (b)) (export x) (begin (define x 1)))
      (define-library (b) (import (a)) (export y) (begin (define y 2)))
      """)

      err =
        assert_raise ArgumentError, fn ->
          Loader.load_file(path, standard())
        end

      message = err.message
      assert message =~ "cycle in define-library"
      assert message =~ "(a)"
      assert message =~ "(b)"
      assert message =~ "#{path}:1:1"
      assert message =~ "#{path}:2:1"
    end
  end

  describe "(include ...)" do
    @tag :tmp_dir
    test "splices body forms from a file relative to the including file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "body.scm"), """
      (define (square x) (* x x))
      (define forty-two 42)
      """)

      File.write!(Path.join(dir, "lib.scm"), """
      (define-library (with-include)
        (import (scheme base))
        (export square forty-two)
        (include "body.scm"))
      """)

      reg = Loader.load_file(Path.join(dir, "lib.scm"), standard())
      lib = Library.fetch!(reg, ["with-include"])

      assert {:var, {:closure, _, _, _, _}} = Map.fetch!(lib.exports, "square")
      assert {:var, 42} = Map.fetch!(lib.exports, "forty-two")
    end

    @tag :tmp_dir
    test "concatenates multiple paths in source order", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.scm"), "(define a 1)")
      File.write!(Path.join(dir, "b.scm"), "(define b (+ a 1))")

      File.write!(Path.join(dir, "lib.scm"), """
      (define-library (multi-include)
        (import (scheme base))
        (export a b)
        (include "a.scm" "b.scm"))
      """)

      reg = Loader.load_file(Path.join(dir, "lib.scm"), standard())
      lib = Library.fetch!(reg, ["multi-include"])
      assert {:var, 1} = Map.fetch!(lib.exports, "a")
      assert {:var, 2} = Map.fetch!(lib.exports, "b")
    end

    @tag :tmp_dir
    test "missing include file errors with the offending path quoted", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "lib.scm"), """
      (define-library (with-include)
        (include "no-such.scm"))
      """)

      assert_raise ArgumentError, ~r/no-such\.scm/, fn ->
        Loader.load_file(Path.join(dir, "lib.scm"), standard())
      end
    end

    @tag :tmp_dir
    test "rejects relative paths that escape the entry-point directory", %{tmp_dir: dir} do
      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)
      File.write!(Path.join(dir, "outside.scm"), "(define x 1)")

      File.write!(Path.join(sub, "lib.scm"), """
      (define-library (escaping)
        (import (scheme base))
        (export x)
        (include "../outside.scm"))
      """)

      assert_raise ArgumentError, ~r/resolves outside/, fn ->
        Loader.load_file(Path.join(sub, "lib.scm"), standard())
      end
    end

    test "relative include without a base directory is an error" do
      source = """
      (define-library (no-base)
        (include "anything.scm"))
      """

      assert_raise ArgumentError, ~r/without a base directory/, fn ->
        Loader.load_string(source, standard())
      end
    end
  end

  describe "(include-library-declarations ...)" do
    @tag :tmp_dir
    test "splices declarations from an external file", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "decls.scm"), """
      (import (scheme base))
      (export answer)
      (begin (define answer 42))
      """)

      File.write!(Path.join(dir, "lib.scm"), """
      (define-library (with-decls)
        (include-library-declarations "decls.scm"))
      """)

      reg = Loader.load_file(Path.join(dir, "lib.scm"), standard())
      lib = Library.fetch!(reg, ["with-decls"])
      assert {:var, 42} = Map.fetch!(lib.exports, "answer")
    end

    @tag :tmp_dir
    test "nested includes resolve relative to the innermost file", %{tmp_dir: dir} do
      sub = Path.join(dir, "sub")
      File.mkdir_p!(sub)

      File.write!(Path.join(sub, "body.scm"), "(define inner 7)")

      File.write!(Path.join(sub, "decls.scm"), """
      (import (scheme base))
      (export inner)
      (include "body.scm")
      """)

      File.write!(Path.join(dir, "lib.scm"), """
      (define-library (nested)
        (include-library-declarations "sub/decls.scm"))
      """)

      reg = Loader.load_file(Path.join(dir, "lib.scm"), standard())
      lib = Library.fetch!(reg, ["nested"])
      assert {:var, 7} = Map.fetch!(lib.exports, "inner")
    end

    @tag :tmp_dir
    test "cond-expand inside an included declaration file works", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "decls.scm"), """
      (cond-expand
        (r7rs (import (scheme base))
              (export who)
              (begin (define who 'r7rs)))
        (else (import (scheme base))
              (export who)
              (begin (define who 'other))))
      """)

      File.write!(Path.join(dir, "lib.scm"), """
      (define-library (cx-included)
        (include-library-declarations "decls.scm"))
      """)

      reg = Loader.load_file(Path.join(dir, "lib.scm"), standard())
      lib = Library.fetch!(reg, ["cx-included"])
      assert {:var, {:sym, "r7rs"}} = Map.fetch!(lib.exports, "who")
    end

    @tag :tmp_dir
    test "import inside an included file is followed for topological order", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "decls.scm"), """
      (import (helpers))
      (export use-help)
      (begin (define use-help (helper)))
      """)

      File.write!(Path.join(dir, "libs.scm"), """
      (define-library (uses)
        (include-library-declarations "decls.scm"))
      (define-library (helpers)
        (import (scheme base))
        (export helper)
        (begin (define (helper) 99)))
      """)

      reg = Loader.load_file(Path.join(dir, "libs.scm"), standard())
      lib = Library.fetch!(reg, ["uses"])
      assert {:var, 99} = Map.fetch!(lib.exports, "use-help")
    end
  end
end
