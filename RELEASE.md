### Changed

- The evaluator is substantially faster: roughly 3-7x on call-heavy code.
  Core forms are now analysed once into an internal representation,
  variable references are resolved to lexical slots ahead of time, and
  the result is compiled into closures, so evaluation no longer
  re-parses forms or looks variables up by name. Each global binding
  has its own cell, read directly at run time. Two-argument integer
  `+ - * = < > <= >=` run inline while those names still mean the
  standard procedures. A named `let`, or any `letrec*` whose lambdas
  are only ever called directly, runs as direct calls with no closures.

  | workload                | 1.0.0    | this release |
  | ----------------------- | -------- | ------------ |
  | fib(20)                 | 20.4 ms  | 3.6 ms       |
  | named-let loop 100k     | 120.7 ms | 16.2 ms      |
  | closures 10k            | 23.6 ms  | 4.0 ms       |
  | list build+map+fold 10k | 25.3 ms  | 5.9 ms       |
  | string build 2k         | 2.6 ms   | 0.8 ms       |

  (Medians from `bench/eval_bench.exs` on OTP 28.5 with JIT.)
- `%Schooner.Compiled{}` now holds the analysed program rather than the
  expanded source forms. It is still plain data, safe to cache or
  persist, and is still opaque.

### Added

- `bench/eval_bench.exs`, an evaluator throughput benchmark with no
  extra dependencies (`MIX_ENV=prod mix run bench/eval_bench.exs`).

### Fixed

- Import modifiers `only`, `except`, and `rename` now reject identifiers
  absent from the inner import set. Scripts that previously imported an
  unknown name silently now fail with a script error.

- Loading a library with `base_dir: "/"` no longer rejects includes
  beneath the filesystem root.

- `digit-value` now returns the correct decimal value for adjacent Unicode
  digit sets, including mathematical styled digits.

- Library sources loaded without a base directory now reject absolute
  include paths as well as relative ones. Load from a file or pass
  `:base_dir` to confine includes to the library root directory.

- Tail loops with internal definitions, including bodies that create
  callbacks, no longer grow the stack or allocate recursive
  process-dictionary slots when binding targets are distinct and
  initializer references only target earlier bindings. Closures in
  these forms retain their captured lexical values, including when
  saved by host primitives. Self and forward references retain
  recursive binding behavior.

- Rational `asin`/`acos` outside the real domain and negative bases
  raised to fractional powers now return complex values. Inexact real
  `expt` and `exp` handle overflow and underflow, and numeric domain or
  range failures return script errors instead of leaking
  Elixir arithmetic exceptions.

- Module documentation and guides no longer contradict the
  implementation in several places, including the representation of
  promises and the empty list, `equal?` on foreign values, how
  out-of-range `asin`/`acos` and negative `sqrt` behave, and how
  include paths are confined when loading libraries.
- The sandboxing examples in the "Running Untrusted Scheme" guide now
  work. They built the environment in one process and evaluated it in
  another, which fails. The first example also passed `:max_heap_size`
  to `Task.Supervisor.async_nolink/3`, which ignores it, so no heap
  limit applied. The examples now set the limit inside the task, give
  it in words rather than bytes, and set `include_shared_binaries:
  true` so that large strings and bytevectors count towards it.
- The "Host Functions" guide told host code to raise `Schooner.Error`
  for errors a script can catch. That exception bypasses Scheme
  handlers. The guide now uses
  `Schooner.Eval.ExceptionState.raise_value/1`, which reaches
  `guard` and `with-exception-handler`.
- The "Special-form names" deviation now describes the actual
  behaviour: rebinding is accepted, but core special forms keep their
  meaning at the head of a form.
