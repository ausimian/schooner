# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

<!-- %% CHANGELOG_ENTRIES %% -->

## 1.2.0 - 2026-10-05

### Added

- Script errors now say where they happened. Every script-level
  exception has a `:location` field holding a `Schooner.Location`
  (`file`, `line`, `column`), or `nil` when the position is unknown.
  Pass `file:` (or `locations: true`) to `Schooner.eval/3` or
  `Schooner.compile/3` to record locations; with `file:` the message
  is prefixed with `file:line:col: `. Tracking positions makes reading
  and expanding a script about 15% slower and costs nothing while it
  runs. Without these options, errors have `location: nil` as before.
  - Located once locations are on: lexer and reader errors, malformed
    special forms and other syntax and expansion errors, an
    `(import ...)` of a missing library, unbound variables, and
    `letrec` bindings read before they are initialised.
  - Located with `debug: true`, which also turns locations on: errors
    raised while applying a procedure, such as primitive type errors,
    arity mismatches, applying a non-procedure, an uncaught `raise`
    or `(error ...)`, and `Schooner.Host.TypeError`. Debug mode wraps
    each primitive call in a `try` and records calls for backtraces
    (below), which together make call-heavy scripts two to three
    times slower. Without it these errors have `location: nil`.
  - An error inside a macro expansion points at the user's code, not
    at the library that defines the macro.
  - Libraries loaded with `Schooner.Library.Loader` always record
    locations. An error in a procedure defined by a library loaded
    from a file points at that file.
  - Compiled programs keep their locations, and `run_compiled/2`
    reports the same locations as `eval/3`.
- `Schooner.format_error/2` renders an error for people. With
  `source:`, it adds an excerpt of the failing line with a caret
  under the column.
- Scheme backtraces in debug mode. With `debug: true`, the evaluator
  keeps a history of the last 32 procedure calls (set
  `:backtrace_depth` to change it) and attaches it to a script error
  as `:scheme_backtrace`, a list of `Schooner.Frame` structs holding
  each call's procedure name, location and whether it was a tail
  call, most recent first. Calls that have returned are dropped, and
  escapes through `guard` and `call/cc` drop the frames they abandon,
  so the backtrace lists the calls still running when the error was
  raised. The history is bounded, so a tail-recursive loop still runs
  in constant memory. `Schooner.format_error/2` prints the backtrace
  after the message. Without `debug`, no history is kept and running
  a script costs the same as before.
- `Schooner.run_compiled/3` and `Schooner.run_compiled!/3` take
  `debug:` and `:backtrace_depth` options, so one compiled program
  can run with or without debug mode.
- `Schooner.check/3` checks a script against a `Schooner.Environment`
  without running it, and returns a list of `Schooner.Diagnostic`s
  with a severity, a code, a message and a location. It reports
  source that doesn't parse (`:read_error`); malformed special forms,
  macro uses and import sets (`:syntax_error`); imports of libraries
  the environment doesn't provide (`:unknown_library`); names that
  nothing binds (`:unbound`); and calls whose argument count a known
  procedure can't accept (`:arity`). The environment is left
  unchanged, so it is safe to call on untrusted scripts.
- `mix schooner.check` runs the checker over files, directories and
  globs, printing `file:line:col: severity[code]: message` lines or,
  with `--format json`, one JSON object. It exits with status 1 when
  it finds errors, or warnings with `--warnings-as-errors`. Choose
  the environment with `--env Mod.fun` or
  `config :schooner, :tooling_environment, {Mod, :fun, args}`;
  without either, every standard library is imported.
- `Schooner.expand/3` shows what a script's macros expand to,
  without running it. It reads the script, resolves its imports
  against a `Schooner.Environment` and returns the expanded top-level
  forms. With `step: :once`, it expands each macro use that isn't
  inside another macro use only once, and leaves the macro uses in
  its output unexpanded. With `trace: true`, it also returns every
  expansion step in order, each with the macro's name, the location
  of the use, and the form before and after. Like `check/3`, it
  leaves the environment unchanged.
- `Schooner.Pretty.format/2` prints Scheme data and code across
  lines, indented the usual way, within a `:width`. Reading the
  output back gives an `equal?` datum, unless it contains
  identifiers a macro introduced. Those are printed with a number,
  as `tmp·1`, so people can tell them apart from the script's own
  (`names: :plain` prints them without it), but they have no written
  form that reads back as the same identifier.
- `mix schooner.expand <file | -e source>` prints a script's
  expansion, with `--once`, `--trace`, `--plain`, `--width` and the
  same `--env` resolution as `mix schooner.check`.
- `Schooner.Debug.library/1` builds `(schooner debug)`, an opt-in
  library for print debugging. Its `(trace label expr)` sends
  `label: value` to a sink and returns the value unchanged, including
  multiple values; `(print obj ...)` sends its arguments' `display`
  text; and `(assert expr)` or `(assert expr message)` raises an
  error, catchable with `guard`, whose message quotes the source of
  `expr`. The `:sink` is `{:logger, level}`, a pid, or a 1-arity
  function, and each message comes with the location of the form
  that sent it. Like `(scheme time)`, the library is not in the
  default registry, so a script can only import it when the embedder
  passes it to `Schooner.Environment.new/1`.
- `Schooner.Session` evaluates one entry after another against a
  `Schooner.Environment`. Each entry sees the definitions, imports
  and `define-syntax` macros of the ones before it. `eval/3` returns
  `{:ok, value, session}` or `{:error, exception, session}`, and an
  error leaves the session usable. `bindings/1` lists the names in
  scope and the libraries that export them.
- `mix schooner.repl` starts an interactive session against your
  environment, with the same `--env` resolution as
  `mix schooner.check`, plus `--load FILE` and `--debug`. Entries
  that end inside an open form continue on the next line. In a
  terminal, that line starts indented to where the code goes, Tab
  re-indents a line, Up and Down recall earlier entries, and Ctrl-C
  interrupts a runaway evaluation and leaves the session as it was
  before it. The commands are `,env [prefix]`, `,expand <form>`,
  `,time <form>`, `,load <file>`, `,help` and `,quit`.
- `Schooner.eval/3` and `Schooner.eval!/3` accept a
  `Schooner.Environment` as well as a `Schooner.Env`.
  `Schooner.compile/3`, `Schooner.compile!/3`, and
  `Schooner.Library.Loader.load_file/3` take options too.

### Changed

- Reading, expanding and analysing a script is about 4% slower, even
  without locations. Running a script is unchanged.
- A `%Schooner.Compiled{}` produced by 1.1.x cannot be run by this
  release, and running one raises. Recompile cached or persisted
  programs after upgrading.
- `Schooner.Library.Loader` now reads `(include ...)` files with
  positions. A reader error in an included file now has the file's
  path in its location and message.

### Fixed

- The README quick example now uses Elixir syntax highlighting on GitHub.
- Large scripts compile faster: the lexer no longer copies the remaining
  source after every identifier, number or character literal.

## 1.1.0 - 2026-10-03

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
  persist, and is still opaque. **A `%Compiled{}` produced by 1.0.x
  cannot be run by this release**: running one raises. Recompile
  cached or persisted programs with `Schooner.compile/2` after
  upgrading.
- Imports and library loading are stricter. An `only`, `except`, or
  `rename` import that names an identifier the library doesn't export,
  or a `rename` whose new name collides with another binding, now fails
  with `Schooner.Eval.Error` instead of being silently ignored or
  overwriting a binding. `Schooner.Library.Loader.load_string/2,3`
  without `:base_dir` now rejects absolute include paths. Scripts and
  libraries that relied on the old behaviour need updating; the
  corresponding entries under Fixed have the details.

### Added

- `Schooner.Host.raise_error/2` and `Schooner.Host.raise_value/1` let host
  functions raise errors that scripts can catch with `guard` or
  `with-exception-handler`.

- `bench/eval_bench.exs`, an evaluator throughput benchmark with no
  extra dependencies (`MIX_ENV=prod mix run bench/eval_bench.exs`).

### Fixed

- Macros defined inside top-level `begin` forms now remain visible to
  later forms even when the `begin` also contains ordinary forms,
  including nested `begin` forms and compiled programs.

- Import `rename` clauses now apply simultaneously, preserving bindings
  in swaps and rotations. Duplicate destinations and renames that would
  overwrite an export retained under its original name now return script errors.

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

- The error for a `define-syntax` outside the top level now says that
  only top-level definitions are supported and suggests `let-syntax`
  or `letrec-syntax`; it previously described only macro-introduced
  definitions. The expired-continuation error no longer refers to an
  internal planning document.

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
  `Schooner.Host.raise_error/2`, which reaches
  `guard` and `with-exception-handler`.
- The "Special-form names" deviation now describes the actual
  behaviour: rebinding is accepted, but core special forms keep their
  meaning at the head of a form.

## 1.0.0 - 2026-05-01

### Added

- Initial release.