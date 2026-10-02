### Changed

- The evaluator is substantially faster: roughly 2x on call-heavy code.
  Core forms are now analysed once into an internal representation,
  variable references are resolved to lexical slots ahead of time, and
  the result is compiled into closures, so evaluation no longer
  re-parses forms or looks variables up by name. Integer `+ - *` and
  `= < > <= >=` also take a fast path for the common two-argument case.

  | workload                | 1.0.0    | this release |
  | ----------------------- | -------- | ------------ |
  | fib(20)                 | 18.7 ms  | 9.4 ms       |
  | named-let loop 100k     | 105.9 ms | 41.5 ms      |
  | closures 10k            | 21.3 ms  | 9.0 ms       |
  | list build+map+fold 10k | 23.3 ms  | 11.6 ms      |

  (Medians from `bench/eval_bench.exs` on OTP 28.3 with JIT.)
- `%Schooner.Compiled{}` now holds the analysed program rather than the
  expanded source forms. It is still plain data, safe to cache or
  persist, and is still opaque.

### Added

- `bench/eval_bench.exs`, an evaluator throughput benchmark with no
  extra dependencies (`MIX_ENV=prod mix run bench/eval_bench.exs`).
