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
| 2 | [Checking scripts before they run](#checking-scripts-before-they-run) | Available | [#136](https://github.com/ausimian/schooner/issues/136) |
| 3 | [Tracing and assertions](#tracing-and-assertions) | Available | [#137](https://github.com/ausimian/schooner/issues/137) |
| 4 | [Backtraces](#backtraces) | Available | [#138](https://github.com/ausimian/schooner/issues/138) |
| 5 | [The REPL](#the-repl) | Available | [#139](https://github.com/ausimian/schooner/issues/139) |
| 6 | [Inspecting macro expansion](#inspecting-macro-expansion) | Available | [#140](https://github.com/ausimian/schooner/issues/140) |
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

3. Otherwise, every shipped standard library, all imported: the
   surface `Schooner.run/1` gives a script that imports nothing.
   This is fine for experiments, but it is wider than any real
   sandbox, so prefer 1 or 2.

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
`try` and records every call for a [backtrace](#backtraces), which
together make call-heavy scripts two to three times slower. Without
it those errors have `location: nil`, so turn it on while you
develop and test scripts, and wherever you want precise errors more
than that speed:

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
`source:` it adds an excerpt, and with `debug: true` the error also
carries the [backtrace](#backtraces) printed after it:

```elixir
IO.puts(Schooner.format_error(error, source: source))
```

```text
scripts/pricing.scm:4:3: type error in `*`: expected number, got "3"
  |
4 |   (* (unit-price sku) qty))
  |   ^

Scheme backtrace (most recent first):
  *            scripts/pricing.scm:4:3 (tail call)
  line-total   scripts/pricing.scm:9:10
  order-total  scripts/pricing.scm:11:1
```

Errors raised while expanding a macro point at the macro's use
site in your script, not into the library that defines the
macro. An error in a procedure defined by a library loaded with
`Schooner.Library.Loader.load_file/3` points into that library's
file; pass `debug: true` to `load_file/3` to locate errors raised
while applying procedures in the library's code. Scripts run
through `Schooner.compile/3` and `Schooner.run_compiled/3` keep
their locations; pass `file:` and `debug:` to `compile`, or
`debug: true` to `run_compiled/3` for one run.

## Checking scripts before they run

**Status: Available** ([#136](https://github.com/ausimian/schooner/issues/136))

`Schooner.check/3` reads a script, resolves its imports and expands
its macros against an environment **without evaluating it**, and
returns a list of `Schooner.Diagnostic`s. An empty list means
nothing was found.

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
| `:syntax_error` | a special form, macro use or `import` set is malformed |
| `:unknown_library` | an `(import ...)` names a library the environment doesn't provide |
| `:unbound` | a name isn't bound by the environment, an import, or a definition in the script |
| `:arity` | a call's argument count can't match a known procedure's arity |

A procedure's arity is known when it is a primitive or procedure
bound by the environment or an import, or when the script defines it
once with `lambda` or `(define (name ...) ...)` and nothing else binds
it.

Every form is checked, including branches that never run, so an
unbound name in dead code is still reported. When an import fails,
the checker can't know which names it would have bound, so it
reports no `:unbound` diagnostics for that script.

Because `check/3` never runs the script and leaves the environment
unchanged, it is safe to call on untrusted input when a script is
saved. Use it to reject broken scripts early and to show diagnostics
in your own UI. It does expand the script's macros, and a macro that
never stops expanding never returns, so call it under a timeout as
you would `Schooner.eval/3`.

From the command line, or in CI: suppose `scripts/` holds
`pricing.scm`, `draft.scm` with the script above, and `discounts.scm`,
which starts with `(import (myapp promos))`. Then:

```console
$ mix schooner.check "scripts/**/*.scm" --env MyApp.Scripts.environment
scripts/discounts.scm:1:9: error[unknown_library]: library not found: (myapp promos)
scripts/draft.scm:1:27: error[unbound]: unbound variable: unit-prise
2 errors in 2 files
```

Arguments can be files, directories or globs; quote globs so the
task expands them rather than the shell. The task exits with status
1 when it finds errors. `--warnings-as-errors` makes warnings fail
too, although every diagnostic the checker reports today is an
error. `--format json` prints machine-readable output.

## Tracing and assertions

**Status: Available** ([#137](https://github.com/ausimian/schooner/issues/137))

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

Take `scripts/order.scm`:

```scheme
(import (schooner debug))

(define (line-total price qty)
  (trace "line-total" (* price qty)))

(define (order-total lines)
  (print "pricing" (length lines) "lines")
  (let ((total (apply + (map (lambda (line) (line-total (car line) (cdr line)))
                             lines))))
    (assert (> total 0))
    total))
```

`(order-total '((10 . 3)))` logs `pricing 1 lines` and
`line-total: 30`, and returns 30. `(order-total '((10 . 0)))` fails
the assertion.

- `(trace label expr)` returns `expr`'s value unchanged, so you
  can wrap any expression in place without restructuring code.
  It sends `label: value`, with the label rendered by `display`
  and the value by `write`. Multiple values pass through, and are
  all written. `trace` has to see the value, so `expr` is not in
  tail position, but tail calls inside `expr` still are: wrapping
  a call to a long-running loop is fine.
- `(print obj ...)` sends the `display` rendering of its
  arguments, separated by spaces.
- `(assert expr)` / `(assert expr message)` raise a normal
  Scheme error, catchable with `guard`, when `expr` is `#f`, and
  otherwise return its value. The error's message is
  `assertion failed:` followed by the source text of `expr`, and
  then by `message`, which is only evaluated when the assertion
  fails.

All three are syntax, so `trace`, `print` and `assert` can't be
passed as values.

Sinks:

| `:sink` | Output goes to |
| --- | --- |
| `{:logger, level}` | `Logger`, with the script location in metadata |
| a pid | the process, as `{:schooner_debug, kind, text, location}` |
| a 1-arity function | the function, called with `%{kind:, text:, location:}` |

`kind` is `:trace` or `:print`. The location is the
`%Schooner.Location{}` of the `trace` or `print` form, recorded on
the same terms as error locations: pass `:file`,
`locations: true` or `debug: true`, or it is `nil`. With the logger
sink it is in the `:schooner_location` metadata, and `kind` is in
`:schooner_debug`. A sink runs in the evaluating process; if it
raises, the script stops with a `Schooner.Primitive.Error` that a
`guard` can't catch.

The pid sink is convenient in tests:

```elixir
env =
  Schooner.Environment.new(
    pre_imports: [["scheme", "base"]],
    libraries: [Schooner.Debug.library(sink: self())]
  )

{:ok, 30} =
  Schooner.eval(source <> "(order-total '((10 . 3)))", env, file: "scripts/order.scm")

assert_receive {:schooner_debug, :print, "pricing 1 lines", _location}
assert_receive {:schooner_debug, :trace, "line-total: 30", %Schooner.Location{line: 4}}
```

A failed assertion is located too:

```elixir
{:error, error} =
  Schooner.eval(source <> "(order-total '((10 . 0)))", env, file: "scripts/order.scm")

error.message
# => "scripts/order.scm:10:5: uncaught Scheme error: assertion failed: (> total 0)"
```

## Backtraces

**Status: Available** ([#138](https://github.com/ausimian/schooner/issues/138))

Schooner implements proper tail calls on top of the BEAM's
last-call optimisation, so there is no Scheme call stack to look
at after an error, and the Elixir stacktrace shows only evaluator
internals. With `debug: true`, the evaluator keeps a bounded
history of recent procedure calls and attaches it to any error
that escapes. Taking the error from
[Source locations in errors](#source-locations-in-errors):

```elixir
{:error, error} =
  Schooner.eval(source <> ~s|(order-total '(("widget" . "3")))|,
                MyApp.Scripts.environment(),
                file: "scripts/pricing.scm", debug: true)

IO.puts(Schooner.format_error(error))
```

```text
scripts/pricing.scm:4:3: type error in `*`: expected number, got "3"

Scheme backtrace (most recent first):
  *            scripts/pricing.scm:4:3 (tail call)
  line-total   scripts/pricing.scm:9:10
  order-total  scripts/pricing.scm:11:1
```

Read it from the bottom up: the top-level call to `order-total` on
line 11 called `line-total` on line 9, which called `*` from tail
position and failed. The history follows calls as they return, so
`unit-price`, which `line-total` called and which returned, isn't
listed. A call marked `(tail call)` replaced the procedure that
made it, so the frame below it is the call it replaced rather than
a caller waiting for its result. A tail-recursive loop shows up as
a run of tail calls. Given `scripts/sum.scm`:

```scheme
(define (sum-firsts lists acc)
  (if (null? lists)
      acc
      (sum-firsts (cdr lists) (+ acc (car (car lists))))))

(sum-firsts '((1) (2) (3) 4) 0)
```

the fourth iteration fails:

```text
scripts/sum.scm:4:38: type error in `car`: expected pair, got 4

Scheme backtrace (most recent first):
  car         scripts/sum.scm:4:38
  sum-firsts  scripts/sum.scm:4:7 (tail call)
  sum-firsts  scripts/sum.scm:4:7 (tail call)
  sum-firsts  scripts/sum.scm:4:7 (tail call)
  sum-firsts  scripts/sum.scm:6:1
```

The history is a ring buffer of the last 32 calls; pass
`:backtrace_depth` to keep more or fewer. A loop overwrites its
oldest entries rather than growing the buffer, so a script that
tail-recurses a million times runs in constant memory with
`debug: true` too.

The raw frames are in `error.scheme_backtrace`, most recent first,
as `%Schooner.Frame{name, location, tail?}`. `name` is the name the
procedure was defined with, a primitive's name, `"<lambda>"` for
an anonymous procedure, or `"<parameter>"` for a parameter object.
With `debug: false` (the default), no
history is kept and `scheme_backtrace` is `nil`. Debug mode is
chosen when the program is compiled to closures, so without it they
contain no history code at all. A compiled program can run with
`Schooner.run_compiled(compiled, environment, debug: true)`, and
errors are located if it was compiled with `file:` or
`locations: true`.

Some calls aren't recorded:

- Arithmetic and comparison on two integers (`+`, `-`, `*`, `=`,
  `<`, `>`, `<=`, `>=`) runs inline and can't fail, so it isn't
  recorded. With any other arguments these calls are recorded like
  any other.
- A procedure that a primitive calls, such as the procedure given
  to `map`, `for-each`, `apply`, `call/cc`, `dynamic-wind` or
  `with-exception-handler`, has no frame of its own: the primitive's
  frame stands in for it. The calls it makes are recorded. Tail
  calls it makes stay in the history until the primitive returns,
  so a procedure that `map` calls several times may leave a frame
  from each call.

Procedures that the evaluator calls directly rather than through a
closure, such as a named `let` loop, are recorded like any other
call, under their name.

Escapes keep the history consistent. When `guard` catches a raise,
or a continuation from `call/cc` is invoked, the calls between the
escape and its target are dropped, so a later error doesn't list
them as callers. When no `guard` clause matches, the raise
continues with the history it had when it was raised.

Recording every call is most of what makes debug mode two to three
times slower on call-heavy scripts. Leave `debug` off where scripts
must run at full speed.

## The REPL

**Status: Available** ([#139](https://github.com/ausimian/schooner/issues/139))

`mix schooner.repl` starts an interactive session against your
real environment. Something that works in the REPL works in
production, and something that's unbound in production is
unbound here too.

```console
$ mix schooner.repl --env MyApp.Scripts.environment --load scripts/pricing.scm
Schooner 1.1.0 — environment: MyApp.Scripts.environment/0. ,help for commands.
schooner> (line-total "widget" 3)
30
schooner> (define (with-shipping x)
     ...>   (+ x 5))
schooner> (with-shipping 30)
35
schooner> (char-upcase #\a)
error: unbound variable: char-upcase
schooner> (import (scheme char))
schooner> (char-upcase #\a)
#\A
schooner> ,env unit
unit-price  (myapp catalog)  procedure, 1 arg
schooner> ,expand (when ok (go))
(if ok (begin (go)))
schooner> ,time (order-total '(("widget" . 2) ("gadget" . 1)))
30  ; 0.1ms, 1650 reductions
schooner> ,quit
```

`char-upcase` is in `(scheme char)`. The environment offers that
library but doesn't import it, so a script must import it, and so
must you.

Definitions, imports and `define-syntax` macros persist from one
entry to the next. An entry that ends inside an open form
continues on the next line. In a terminal, each new line starts
indented to where the code goes, as `Schooner.Pretty` lays it out:
the body of a `define`, `lambda` or `let` two columns in, the
arguments of a call under the first, and the bindings of a `let`
under each other. So you type the code, not the spaces. Tab
re-indents a line, Up and Down recall earlier entries, and pasted
code keeps its own indentation.

An error is printed and the session carries on. Ctrl-C interrupts
an evaluation that runs too long, leaving the session as it was
before that entry, and Ctrl-D or `,quit` leaves. `--debug` turns
on [backtraces](#backtraces) for errors.

| Command | Does |
| --- | --- |
| `,env [prefix]` | list bindings in scope: name, library and what it is |
| `,expand <form>` | show the full expansion (see [below](#inspecting-macro-expansion)) |
| `,time <form>` | evaluate and report wall time and reductions |
| `,load <file>` | evaluate a file into the session |
| `,help`, `,quit` | |

When standard input isn't a terminal, the REPL reads whole lines
without editing or indenting them, so you can pipe a script into
it. Ctrl-C then reaches the BEAM, as it does in any mix task.

To build your own console (a web console, an admin-panel
console), use the same session API the REPL is built on:

```elixir
session = Schooner.Session.new(MyApp.Scripts.environment())
{:ok, _, session} = Schooner.Session.eval(session, "(define x 41)")
{:ok, 42, _session} = Schooner.Session.eval(session, "(+ x 1)")
```

`Schooner.Session.bindings/1` lists what's in scope, as `,env`
does, and `Schooner.Session.environment/1` passes the session's
macros to `Schooner.expand/3`.

## Inspecting macro expansion

**Status: Available** ([#140](https://github.com/ausimian/schooner/issues/140))

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

- `step: :once` expands each macro use that isn't inside another
  macro use once, and leaves the macro uses in its output
  unexpanded.
- `trace: true` also returns each expansion step, in the order it
  happened, as `%{macro:, location:, before:, after:}`.

`mix schooner.expand` takes a file, or the source with `-e`, and
the same `--env` as `mix schooner.check`. `--trace` lists the steps
before the result:

```console
$ mix schooner.expand -e "(let loop ((i 0)) (when (< i 3) (loop (+ i 1))))" --trace
[1] let at 1:1
    (let loop ((i 0)) (when (< i 3) (loop (+ i 1))))
 => (letrec*·1 ((loop (lambda (i) (when (< i 3) (loop (+ i 1)))))) (loop 0))

[2] when at 1:19
    (when (< i 3) (loop (+ i 1)))
 => (if (< i 3) (begin (loop (+ i 1))))

(letrec* ((loop (lambda (i) (if (< i 3) (begin (loop (+ i 1))))))) (loop 0))
```

Identifiers a macro introduces are renamed so they can't clash with
yours, and are printed with a number (`letrec*·1` above), so you
can tell a macro's own `tmp` from yours. Pass `names: :plain` to
`Schooner.Pretty.format/2`, or `--plain` to the task, to print plain
names. Like `check/3`, `expand/3` never evaluates the program.

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
