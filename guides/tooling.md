# Tooling for Script Authors

This guide covers the tools for writing, checking, testing and
debugging Schooner scripts: error locations, a static checker,
tracing, backtraces, a REPL, a macro expander, a test library,
surface documentation and editor integration.

> #### Roadmap {: .warning}
>
> Most of this guide describes **planned** tooling, tracked in
> [#134](https://github.com/ausimian/schooner/issues/134) and
> developed on the `feature/tooling` branch. Each section names its
> issue and status. Sections marked **Planned** show the intended
> API; it may change before it ships. When a feature lands on
> `feature/tooling`, its section is marked **Available** and its
> examples are verified. The branch merges into `main` once the
> roadmap, or a releasable part of it, is complete.

| # | Feature | Status | Issue |
| --- | --- | --- | --- |
| 1 | [Source locations in errors](#source-locations-in-errors) | Available | [#135](https://github.com/ausimian/schooner/issues/135) |
| 2 | [Checking scripts before they run](#checking-scripts-before-they-run) | Planned | [#136](https://github.com/ausimian/schooner/issues/136) |
| 3 | [Tracing and assertions](#tracing-and-assertions) | Planned | [#137](https://github.com/ausimian/schooner/issues/137) |
| 4 | [Backtraces](#backtraces) | Planned | [#138](https://github.com/ausimian/schooner/issues/138) |
| 5 | [The REPL](#the-repl) | Planned | [#139](https://github.com/ausimian/schooner/issues/139) |
| 6 | [Inspecting macro expansion](#inspecting-macro-expansion) | Planned | [#140](https://github.com/ausimian/schooner/issues/140) |
| 7 | [Testing scripts](#testing-scripts) | Planned | [#141](https://github.com/ausimian/schooner/issues/141) |
| 8 | [Documenting your scripting surface](#documenting-your-scripting-surface) | Planned | [#142](https://github.com/ausimian/schooner/issues/142) |
| 9 | [Editor integration](#editor-integration) | Planned | [#143](https://github.com/ausimian/schooner/issues/143) |

## The running example

The examples below share one embedder-defined environment. Keeping
it in a named, zero-arity function lets the mix tasks, the REPL,
the test helpers and the language server all use **the same
sandbox your application uses**:

```elixir
defmodule MyApp.Scripts do
  alias Schooner.Host

  def environment do
    Schooner.Environment.new(
      standard_libraries: [:base, :char, :write],
      pre_imports: [["scheme", "base"]],
      libraries: [
        Host.library(
          name: ["myapp", "catalog"],
          primitives: [
            {"unit-price", 1, &unit_price/1}
          ]
        )
      ]
    )
  end

  defp unit_price([sku]), do: MyApp.Catalog.price(Host.to_string!(sku, op: "unit-price"))
end
```

and one script, `scripts/pricing.scm`:

```scheme
(import (myapp catalog))

(define (line-total sku qty)
  (* (unit-price sku) qty))

(define (order-total lines)
  (if (null? lines)
      0
      (+ (line-total (car (car lines)) (cdr (car lines)))
         (order-total (cdr lines)))))
```

### Telling the tools which environment to use

Every mix task in this guide resolves its environment the same
way, first match wins:

1. `--env MyApp.Scripts.environment` on the command line: a
   zero-arity function returning a `%Schooner.Environment{}`.
2. Application config:

   ```elixir
   # config/dev.exs
   config :schooner, :tooling_environment, {MyApp.Scripts, :environment, []}
   ```

3. Otherwise, every shipped standard library, the same surface
   `Schooner.run/1` sees. This is fine for experiments, but it is
   wider than any real sandbox, so prefer 1 or 2.

## Source locations in errors

**Status: Available** ([#135](https://github.com/ausimian/schooner/issues/135))

Every script-level exception carries a `:location` (a
`%Schooner.Location{file, line, column}`, or `nil`), and when the
location names a file its message is prefixed with
`file:line:col`. Pass `:file` to turn locations on and name the
script, or `locations: true` to turn them on without a name.
Tracking positions makes reading and expanding a script about 15%
slower but costs nothing while it runs; without either option
errors have `location: nil`.

With locations on, reader errors, malformed special forms and other
syntax errors, imports of missing libraries, and unbound variables
are located. Errors raised while *applying* a procedure, such as a
primitive's type error, an arity mismatch or an uncaught
`(error ...)`, are located only when you pass `debug: true`, which
also turns locations on. Debug mode wraps each primitive call in a
`try`, which makes scripts that spend their time in primitives
(list, string and vector work) 10–15% slower; arithmetic on
integers is unaffected. Without it those errors have
`location: nil`, so turn it on while you develop and test scripts,
and wherever you want precise errors more than that speed:

```elixir
source = File.read!("scripts/pricing.scm")

{:error, error} =
  Schooner.eval(source <> ~s|(order-total '(("widget" . "3")))|,
                MyApp.Scripts.environment(),
                file: "scripts/pricing.scm", debug: true)

error.location
# => %Schooner.Location{file: "scripts/pricing.scm", line: 4, column: 3}
```

`Schooner.format_error/2` renders the error for people. With
`source:` it adds an excerpt:

```elixir
IO.puts(Schooner.format_error(error, source: source))
```

```text
scripts/pricing.scm:4:3: type error in `*`: expected number, got "3"
  |
4 |   (* (unit-price sku) qty))
  |   ^
```

Errors raised while expanding a macro point at the macro's use
site in your script, not into the library that defines the
macro. An error in a procedure defined by a library loaded with
`Schooner.Library.Loader.load_file/3` points into that library's
file; pass `debug: true` to `load_file/3` to locate errors raised
while applying procedures in the library's code. Scripts run
through `Schooner.compile/3` and `Schooner.run_compiled/2` keep
their locations; pass `file:` and `debug:` to `compile`.

## Checking scripts before they run

**Status: Planned** ([#136](https://github.com/ausimian/schooner/issues/136))

`Schooner.check/3` reads, resolves imports and expands a script
against an environment **without evaluating it**, and returns a
list of diagnostics. An empty list means nothing was found.

```elixir
Schooner.check(~s|(import (myapp catalog)) (unit-prise "widget")|,
               MyApp.Scripts.environment(),
               file: "draft.scm")
# => [
#      %Schooner.Diagnostic{
#        severity: :error,
#        code: :unbound,
#        message: "unbound variable: unit-prise",
#        location: %Schooner.Location{file: "draft.scm", line: 1, column: 27}
#      }
#    ]
```

| Code | Meaning |
| --- | --- |
| `:read_error` | the source doesn't parse (unbalanced parens, bad literal) |
| `:syntax_error` | a special form or macro use is malformed |
| `:unknown_library` | an `(import ...)` names a library the environment doesn't provide |
| `:unbound` | a name isn't bound by the environment, an import, or a definition in the script |
| `:arity` | a call's argument count can't match a known procedure's arity |

Because `check/3` never runs the script, it is safe to call on
untrusted input when a script is saved. Use it to reject broken
scripts early and to show diagnostics in your own UI.

From the command line, or in CI:

```console
$ mix schooner.check "scripts/**/*.scm" --env MyApp.Scripts.environment
scripts/pricing.scm:4:7: error[unbound]: unbound variable: unit-prise
scripts/discounts.scm:1:9: error[unknown_library]: no library named (myapp promos)
2 errors in 2 files
```

The task exits non-zero when it finds errors.
`--warnings-as-errors` makes warnings fail too, and
`--format json` prints machine-readable output.

## Tracing and assertions

**Status: Planned** ([#137](https://github.com/ausimian/schooner/issues/137))

In Schooner, `display` and `write` *return* their rendered text
rather than writing it anywhere (see
[Deviations](deviations.md)), so they can't be used for print
debugging. Instead, the opt-in `(schooner debug)` library sends
output to a sink the embedder chooses. Like `(scheme time)`, it
is not in the default registry. A script can only import it when
you pass the library in:

```elixir
env =
  Schooner.Environment.new(
    pre_imports: [["scheme", "base"]],
    libraries: [Schooner.Debug.library(sink: {:logger, :debug})]
  )
```

```scheme
(import (schooner debug))

(define (line-total sku qty)
  (trace "line-total" (* (unit-price sku) qty)))  ; logs "line-total: 30", returns 30

(print "pricing" (length lines) "lines")          ; logs "pricing 3 lines"

(assert (> total 0))
;; on failure raises: assertion failed: (> total 0)
```

- `(trace label expr)` returns `expr`'s value unchanged, so you
  can wrap any expression in place without restructuring code.
- `(print obj ...)` sends the `display` rendering of its
  arguments.
- `(assert expr)` / `(assert expr message)` raise a normal
  Scheme error, catchable with `guard`. Its message includes the
  source text of `expr`.

Sinks:

| `:sink` | Output goes to |
| --- | --- |
| `{:logger, level}` | `Logger`, with the script location in metadata |
| a pid | the process, as `{:schooner_debug, kind, text, location}` |
| a 1-arity function | the function, called with `%{kind:, text:, location:}` |

The pid sink is convenient in tests:

```elixir
env =
  Schooner.Environment.new(
    pre_imports: [["scheme", "base"]],
    libraries: [Schooner.Debug.library(sink: self())]
  )

Schooner.eval(source, env)
assert_receive {:schooner_debug, :trace, "line-total: 30", _location}
```

## Backtraces

**Status: Planned** ([#138](https://github.com/ausimian/schooner/issues/138))

Schooner implements proper tail calls on top of the BEAM's
last-call optimisation, so there is no Scheme call stack to look
at after an error. With `debug: true`, the evaluator keeps a
bounded history of recent procedure calls and attaches it to any
error that escapes:

```elixir
{:error, error} =
  Schooner.eval(source, MyApp.Scripts.environment(),
                file: "scripts/pricing.scm", debug: true)

IO.puts(Schooner.format_error(error, source: source))
```

```text
scripts/pricing.scm:4:3: type error in `*`: expected number, got "3"
  |
4 |   (* (unit-price sku) qty))
  |   ^

Scheme backtrace (most recent first):
  line-total    scripts/pricing.scm:9:10
  order-total   scripts/pricing.scm:11:1
```

The raw frames are in `error.scheme_backtrace` as
`%Schooner.Frame{name, location, tail?}`. The history is a ring
buffer (`:backtrace_depth`, default 32), so tail calls appear
in it but a long-running loop can't grow it without limit. With
`debug: false` (the default), no history is kept.

## The REPL

**Status: Planned** ([#139](https://github.com/ausimian/schooner/issues/139))

`mix schooner.repl` starts an interactive session against your
real environment. Something that works in the REPL works in
production, and something that's unbound in production is
unbound here too.

```console
$ mix schooner.repl --env MyApp.Scripts.environment --load scripts/pricing.scm
Schooner 1.x — environment: MyApp.Scripts.environment/0. ,help for commands.
schooner> (line-total "widget" 3)
30
schooner> (define (with-shipping x)
     ...>   (+ x 5))
schooner> (with-shipping 30)
35
schooner> (string-upcase "hi")
error: unbound variable: string-upcase
schooner> ,env unit
unit-price    (myapp catalog)   procedure, 1 arg
schooner> ,expand (when ok (go))
(if ok (begin (go)))
schooner> ,time (order-total big-order)
1204.5  ; 3.1ms, 48211 reductions
schooner> ,quit
```

Definitions, imports and `define-syntax` macros persist across
inputs. Input that ends inside an open form continues on the
next line. `--debug` turns on [backtraces](#backtraces) for
errors.

| Command | Does |
| --- | --- |
| `,env [prefix]` | list bindings in scope |
| `,expand <form>` | show the full expansion (see [below](#inspecting-macro-expansion)) |
| `,time <form>` | evaluate and report wall time and reductions |
| `,load <file>` | evaluate a file into the session |
| `,help`, `,quit` | |

To build your own console (a web console, an admin-panel
console), use the same session API the REPL is built on:

```elixir
session = Schooner.Session.new(MyApp.Scripts.environment())
{:ok, _, session} = Schooner.Session.eval(session, "(define x 41)")
{:ok, 42, _session} = Schooner.Session.eval(session, "(+ x 1)")
```

## Inspecting macro expansion

**Status: Planned** ([#140](https://github.com/ausimian/schooner/issues/140))

Many of Schooner's standard forms (`cond`, `case`, the `let`
family, `do`, `and`, `or`, `when`, `unless`) are `syntax-rules`
macros. When they, or your own macros, surprise you, look at the
expansion:

```elixir
{:ok, [form]} = Schooner.expand("(when (> n 0) (go n))", MyApp.Scripts.environment())
IO.puts(Schooner.Pretty.format(form))
# (if (> n 0) (begin (go n)))
```

Options:

- `step: :once` expands only the outermost macro use of each
  form.
- `trace: true` also returns each expansion step as
  `%{macro:, location:, before:, after:}`.

```console
$ mix schooner.expand -e "(let loop ((i 0)) (when (< i 3) (loop (+ i 1))))" --trace
[1] let (named)  <stdin>:1:1
    (let loop ((i 0)) ...)
 => (letrec* ((loop (lambda (i) ...))) (loop 0))
[2] when  <stdin>:1:19
    (when (< i 3) (loop (+ i 1)))
 => (if (< i 3) (begin (loop (+ i 1))))
```

Hygienically renamed identifiers are printed distinctly (e.g.
`tmp·1`), so you can tell a macro's own `tmp` from yours. Like
`check/3`, `expand/3` never evaluates the program.

## Testing scripts

**Status: Planned** ([#141](https://github.com/ausimian/schooner/issues/141))

The opt-in `(schooner test)` library provides an SRFI-64-style
API: `test-equal`, `test-eqv`, `test-assert`, `test-not`,
`test-error` and `test-group`. A failing assertion is recorded
and the file keeps running, so one run reports every failure.

`test/scripts/pricing_test.scm`:

```scheme
(import (scheme base) (schooner test))

(test-group "line-total"
  (test-equal "single widget" 10 (line-total "widget" 1))
  (test-equal "bulk widgets" 90 (line-total "widget" 10))
  (test-error "unknown sku" (line-total "nope" 1)))
```

Run it from ExUnit with `Schooner.Case`:

```elixir
defmodule MyApp.PricingScriptTest do
  use Schooner.Case, environment: &MyApp.Scripts.environment/0

  # Loaded before each test file, e.g. the code under test.
  @scheme_preload ["scripts/pricing.scm"]

  scheme_test "test/scripts/pricing_test.scm"
end
```

Each top-level `test-group` becomes one ExUnit test. A failing
test lists every failing assertion with its location:

```text
  1) test line-total (MyApp.PricingScriptTest)
     test/scripts/pricing_test.scm:5:3: bulk widgets
       expected: 90
       got:      100
       expr:     (line-total "widget" 10)
```

`mix test` recompiles the test module when its `.scm` file
changes.

## Documenting your scripting surface

**Status: Planned** ([#142](https://github.com/ausimian/schooner/issues/142))

Script authors can only use what your environment exposes, so
they need a reference for it. Add docs to your host primitives
with an optional fourth element:

```elixir
Host.library(
  name: ["myapp", "catalog"],
  primitives: [
    {"unit-price", 1, &unit_price/1,
     doc: "(unit-price sku) — current unit price for `sku`, a string."}
  ]
)
```

Then list the surface from code:

```elixir
Schooner.Environment.surface(MyApp.Scripts.environment())
# => [
#      %{name: "unit-price", kind: :procedure, arity: 1,
#        library: ["myapp", "catalog"], imported?: false,
#        doc: "(unit-price sku) — current unit price for `sku`, a string."},
#      %{name: "car", kind: :procedure, arity: 1, library: ["scheme", "base"],
#        imported?: true, doc: "..."},
#      ...
#    ]
```

or generate a reference page for your users:

```console
$ mix schooner.surface --env MyApp.Scripts.environment --format markdown > docs/scripting-reference.md
```

The shipped standard libraries carry one-line docs for every
export, so the generated page is complete without extra work.

## Editor integration

**Status: Planned** ([#143](https://github.com/ausimian/schooner/issues/143))

A language server, shipped as a separate package so `schooner`
itself stays dependency-light, brings the tools above into the
editor:

- **diagnostics** as you type, from
  [`Schooner.check/3`](#checking-scripts-before-they-run)
- **completion** of exactly the names your environment exposes,
  plus the file's own definitions
- **hover** docs from
  [`Environment.surface/1`](#documenting-your-scripting-surface)
- **go to definition** for top-level definitions

The planned setup: add the package to your project's `:dev`
dependencies and tell it which environment and files to use:

```elixir
# .schooner.exs
[
  environment: {MyApp.Scripts, :environment, []},
  include: ["scripts/**/*.scm", "test/scripts/**/*.scm"]
]
```

Then point your editor's generic LSP client at
`mix schooner_ls` for `scheme` files. Editor-specific snippets
will be added here when the server ships.
