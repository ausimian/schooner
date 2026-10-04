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
