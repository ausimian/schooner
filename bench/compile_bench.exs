# Compile-path scaling benchmark, including lexing, reading, macro expansion
# and analysis. Source generation and environment setup are outside the timer.
#
# Run with: MIX_ENV=prod mix run bench/compile_bench.exs
#
# Each size contains two definitions per group from issue #161. Report the
# median over at least five samples and roughly one second, with and without
# source locations. All calls stay in the process that owns the environment.

defmodule CompileBench do
  alias Schooner.Environment
  alias Schooner.Value

  @sizes [25, 50, 100, 200, 500, 1_000]
  @run_ms 1_000

  def run do
    for opts <- [[], [file: "compile-bench.scm"]] do
      IO.puts("\nCompile options: #{inspect(opts)}")
      IO.puts("groups  forms    bytes    median µs   doubling ratio")

      Enum.reduce(@sizes, nil, fn size, previous ->
        source = source(size)
        env = Environment.new(pre_imports: [["scheme", "base"]])
        fun = fn -> Schooner.compile!(source, env, opts) end
        compiled = fun.()

        expected =
          Value.list([7_500, Value.list(Enum.map(~w(low low mid mid hi), &Value.symbol/1))])

        unless Schooner.run_compiled!(compiled, env) == expected,
          do: raise("incorrect result for #{size} groups")

        :erlang.garbage_collect()
        deadline = System.monotonic_time(:millisecond) + @run_ms
        samples = sample(fun, deadline, [], 0) |> Enum.sort()
        median = Enum.at(samples, div(length(samples), 2))

        ratio =
          case previous do
            {previous_size, previous_us} when size == previous_size * 2 ->
              :erlang.float_to_binary(median / max(previous_us, 1), decimals: 2)

            _ ->
              "-"
          end

        IO.puts(
          "#{pad(size, 6)} #{pad(size * 2 + 1, 6)} #{pad(byte_size(source), 8)} " <>
            "#{pad(median, 12)} #{pad(ratio, 16)}"
        )

        {size, median}
      end)
    end
  end

  defp source(size) do
    definitions =
      for i <- 1..size do
        """
        (define (loop#{i} i acc)
          (cond ((> i 100) acc)
                ((even? i) (loop#{i} (+ i 1) (+ acc i)))
                (else (let* ((a (* i 2)) (b (- a 1))) (loop#{i} (+ i 1) (+ acc b))))))
        (define v#{i} (map (lambda (x) (case x ((1 2) 'low) ((3 4) 'mid) (else 'hi))) (list 1 2 3 4 5)))
        """
      end

    IO.iodata_to_binary([definitions, "(list (loop#{size} 0 0) v#{size})"])
  end

  defp sample(fun, deadline, acc, count) do
    {us, _compiled} = :timer.tc(fun)
    acc = [us | acc]
    count = count + 1

    if System.monotonic_time(:millisecond) < deadline or count < 5,
      do: sample(fun, deadline, acc, count),
      else: acc
  end

  defp pad(value, width), do: value |> to_string() |> String.pad_leading(width)
end

CompileBench.run()
