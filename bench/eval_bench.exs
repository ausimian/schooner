# Evaluator throughput benchmark. Times a handful of call-heavy
# workloads through the compile-once / run-many path, so the numbers
# reflect evaluator cost rather than lexing, reading, or expansion.
#
# Run with: `MIX_ENV=prod mix run bench/eval_bench.exs`
#
# Each workload is run repeatedly for ~2s after a short warm-up and the
# median wall-clock time is reported. Everything runs in the calling
# process: an environment's globals live in the process dictionary of
# the process that built it, so the env cannot be shared with Tasks.

defmodule EvalBench do
  @run_ms 2_000
  @warmup_ms 300

  @workloads [
    {"fib(20)",
     """
     (define (fib n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2)))))
     (fib 20)
     """, 6765},
    {"named-let loop 100k",
     """
     (let loop ((i 0) (acc 0))
       (if (> i 100000) acc (loop (+ i 1) (+ acc i))))
     """, 5_000_050_000},
    {"closures 10k",
     """
     (define (compose f g) (lambda (x) (f (g x))))
     (define h (compose (lambda (x) (+ x 1)) (lambda (x) (* x 2))))
     (let loop ((i 0) (acc 0))
       (if (= i 10000) acc (loop (+ i 1) (+ acc (h i)))))
     """, 100_000_000},
    {"list build+map+fold 10k",
     """
     (define (build n acc) (if (= n 0) acc (build (- n 1) (cons n acc))))
     (define (sum l acc) (if (null? l) acc (sum (cdr l) (+ acc (car l)))))
     (sum (map (lambda (x) (* x 2)) (build 10000 '())) 0)
     """, 100_010_000},
    {"string build 2k",
     """
     (define (go i acc)
       (if (> i 2000) acc (go (+ i 1) (cons (number->string i) acc))))
     (string-length (apply string-append (reverse (go 1 '()))))
     """, 6893}
  ]

  def run do
    env = Schooner.Environment.new(pre_imports: [["scheme", "base"]])

    for {label, src, expected} <- @workloads do
      compiled = Schooner.compile!(src, env)
      fun = fn -> Schooner.run_compiled!(compiled, env) end

      case fun.() do
        ^expected -> :ok
        other -> raise "#{label}: expected #{inspect(expected)}, got #{inspect(other)}"
      end

      repeat_for(fun, @warmup_ms)
      :erlang.garbage_collect()
      samples = Enum.sort(sample_for(fun, @run_ms, []))
      median = Enum.at(samples, div(length(samples), 2))

      IO.puts(
        "#{String.pad_trailing(label, 26)} median #{String.pad_leading(Integer.to_string(median), 8)} µs  (n=#{length(samples)})"
      )
    end
  end

  defp repeat_for(fun, ms) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_repeat(fun, deadline)
  end

  defp do_repeat(fun, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      fun.()
      do_repeat(fun, deadline)
    end
  end

  defp sample_for(fun, ms, acc) do
    deadline = System.monotonic_time(:millisecond) + ms
    do_sample(fun, deadline, acc)
  end

  defp do_sample(fun, deadline, acc) do
    {us, _} = :timer.tc(fun)
    acc = [us | acc]

    if System.monotonic_time(:millisecond) < deadline or length(acc) < 5,
      do: do_sample(fun, deadline, acc),
      else: acc
  end
end

EvalBench.run()
