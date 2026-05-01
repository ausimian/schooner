defmodule Schooner.Conformance.ChibiR7rsTest do
  # Conformance tests adapted from Chibi-Scheme's r7rs-tests.scm.
  #
  # Each `.scm` file in `test/conformance/scheme/` is one curated
  # section of upstream Chibi's r7rs-tests.scm, with adaptations
  # documented inline at the top of each file (mutation removed,
  # rational/complex numbers stripped, missing primitives skipped,
  # etc.). The shared `_harness.scm` defines the SRFI-64 surface
  # (`test`, `test-assert`, `test-not`, `test-error`, `test-begin`,
  # `test-end`) used by the section files.
  #
  # Each section file becomes one ExUnit test case; the harness is
  # prepended to its content and the combined source is fed through
  # `Schooner.run/1`. Any assertion failure inside the section
  # raises a Scheme exception that bubbles out of `run/1` and
  # ExUnit reports it.
  #
  # The conformance suite is fail-fast within each section: the
  # first failing assertion stops that section, but other sections
  # continue to run. That granularity is the practical compromise
  # for a pure-Scheme harness with no mutation to accumulate
  # failure counters.

  use ExUnit.Case, async: true

  @scheme_dir Path.join(__DIR__, "scheme")
  @harness_path Path.join(@scheme_dir, "_harness.scm")
  @harness_source File.read!(@harness_path)

  @section_paths @scheme_dir
                 |> File.ls!()
                 |> Enum.reject(&String.starts_with?(&1, "_"))
                 |> Enum.filter(&String.ends_with?(&1, ".scm"))
                 |> Enum.sort()
                 |> Enum.map(&Path.join(@scheme_dir, &1))

  @external_resource @harness_path
  for path <- @section_paths do
    @external_resource path
  end

  for path <- @section_paths do
    section_name =
      path
      |> Path.basename(".scm")
      |> String.replace("_", " ")

    test "Chibi r7rs subset — #{section_name}" do
      source = unquote(@harness_source) <> "\n" <> File.read!(unquote(path))
      Schooner.run!(source)
    end
  end
end
