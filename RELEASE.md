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
    each primitive call in a `try`, which makes scripts that spend
    their time in primitives 10–15% slower. Without it these errors
    have `location: nil`.
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
