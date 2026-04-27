# Microbenchmark for the codepoint-based string primitives. Compares the
# wall-clock cost of `string-ref`, `substring`, `string-copy`,
# `string->list`, and `string->utf8` across input sizes 100 / 1k / 10k.
#
# Run with: `mix run bench/string_ops_bench.exs`
#
# Output is a small table per primitive showing min / mean / max time over
# `@iters` repetitions. No external bench dependency — `:timer.tc/1` is
# enough for the size of effect we expect (single-walk vs. 2N walks).

defmodule StringOpsBench do
  @iters 200

  @sizes [100, 1_000, 10_000]

  # Mix ASCII and a 2-byte codepoint so we exercise multi-byte UTF-8 too.
  # Returns exactly `n` codepoints (assumes n is a multiple of 4).
  defp build(n), do: String.duplicate("abcé", div(n, 4))

  defp time(fun) do
    {us, _} = :timer.tc(fun)
    us
  end

  defp stats(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    sum = Enum.sum(sorted)

    %{
      min: List.first(sorted),
      mean: div(sum, n),
      median: Enum.at(sorted, div(n, 2)),
      max: List.last(sorted)
    }
  end

  defp measure(label, fun) do
    # Warm-up.
    Enum.each(1..10, fn _ -> fun.() end)
    samples = for _ <- 1..@iters, do: time(fun)
    s = stats(samples)
    IO.puts("  #{String.pad_trailing(label, 28)} min=#{s.min}µs  mean=#{s.mean}µs  median=#{s.median}µs  max=#{s.max}µs")
  end

  def run do
    Enum.each(@sizes, fn n ->
      s = build(n)
      # Build the source as a raw literal — `inspect/1` truncates large
      # printable binaries via `:printable_limit`, which would corrupt the
      # source for the 10k input. `s` is constrained to chars safe in a
      # Scheme string literal (no `"` or `\`).
      src = ~s|(define s "| <> s <> ~s|")|
      Schooner.run(src)

      IO.puts("\nInput size: #{n} codepoints (#{byte_size(s)} bytes)")

      measure("string-ref s/2", fn -> Schooner.run("#{src} (string-ref s #{div(n, 2)})") end)
      measure("substring s/4-3/4", fn -> Schooner.run("#{src} (substring s #{div(n, 4)} #{div(3 * n, 4)})") end)
      measure("string-copy s", fn -> Schooner.run("#{src} (string-copy s)") end)
      measure("string-copy s/4-3/4", fn -> Schooner.run("#{src} (string-copy s #{div(n, 4)} #{div(3 * n, 4)})") end)
      measure("string->list s", fn -> Schooner.run("#{src} (string->list s)") end)
      measure("string->utf8 s", fn -> Schooner.run("#{src} (string->utf8 s)") end)
    end)
  end
end

StringOpsBench.run()
