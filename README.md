# Schooner

An embeddable, sandboxed Scheme interpreter for the BEAM, targeting the
r7rs-small language minus its mutable operations. Schooner is intended as
a scripting layer for Elixir applications: hosts hand a script source
to one of the entry points below, get back an Elixir term, and
resource-bound the work with the standard process tools
(`:max_heap_size`, `Task.shutdown/2`).

## Quick example

```iex
iex> alias Schooner.Host
iex> env =
...>   Schooner.Environment.new(
...>     pre_imports: [["scheme", "base"]],
...>     libraries: [
...>       Host.library(
...>         primitives: [
...>           {"shout", 1, fn [msg] ->
...>              text = Host.to_string!(msg, op: "shout")
...>              Host.string(String.upcase(text) <> "!")
...>            end}
...>         ]
...>       )
...>     ]
...>   )
iex> Schooner.eval(~s|(shout (string-append "hello, " "world"))|, env)
{:ok, "HELLO, WORLD!"}
iex> {:ok, double} = Schooner.eval("(lambda (x) (* x 2))", env)
iex> Schooner.apply(double, [21])
{:ok, 42}
```

What's happening:

- `Schooner.Environment.new/1` builds a sandbox surface — `(scheme base)` is pre-imported (so `string-append`, `lambda`, `*` are in scope without an explicit `(import ...)`), plus an anonymous host library exposing `shout` as a Scheme procedure backed by an Elixir function.
- `Schooner.eval/2` returns `{:ok, value}` on success. `Schooner.Host.to_string!/2` extracts the underlying binary; `Schooner.Host.string/1` constructs a Scheme string for the return.
- `Schooner.apply/2` invokes any Scheme procedure value (closure, primitive, or parameter) from Elixir.

See the [Embedding](https://hexdocs.pm/schooner/embedding.html) and [Host Functions](https://hexdocs.pm/schooner/host-functions.html) guides for the full story.

## Installation

Add `schooner` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:schooner, "~> 1.0"}
  ]
end
```

Documentation is published at <https://hexdocs.pm/schooner>.

## Choosing an entry point

Schooner has two top-level evaluation entry points. They differ in
**what's in scope when the script starts**, and picking the wrong one
for untrusted input is a sandbox hole.

| Entry point        | Auto-imports                                                                              | Trust posture                                       | Use for                                                            |
| ---                | ---                                                                                       | ---                                                 | ---                                                                |
| `Schooner.run/1`   | injects `(import ...)` of every shipped standard library when the script declares none    | **Not sandbox-safe.** Every primitive is in scope.  | tests, REPL-style use, your own scripts                              |
| `Schooner.eval/2`  | none — bindings come from `env` and the script's own `(import ...)` declarations          | **Sandbox-safe.** The embedder controls the surface.| embedding scripts you do not control                                |

For untrusted input, use `Schooner.eval/2`. A script that omits
`(import ...)` cannot reach any primitive, so the embedder sets the
surface deliberately.

Both functions also have raising bang variants (`run!/1`, `eval!/2,3`)
and a richer environment-construction path via
`Schooner.Environment.new/1` — see the [Embedding](guides/embedding.md)
guide.

## Deviations from r7rs-small

Schooner targets r7rs-small but deliberately ships a smaller surface.
The table below summarises every intentional gap; conformance tests
under `test/conformance/` cover the surface that *is* shipped, with
each excluded upstream case annotated inline. The
[Deviations](guides/deviations.md) guide expands every row with a
runnable example and a workaround.

| Area                         | Schooner                                                                                                                                                  |
| ---                          | ---                                                                                                                                                       |
| Mutation                     | None. `set!`, `set-car!`, `set-cdr!`, `string-set!`, `vector-set!`, `bytevector-u8-set!`, record mutators, `string-fill!`/`copy!`, `vector-fill!`/`copy!`, `list-set!` are not defined. |
| Numeric procedures           | Inexact reals are double-precision only.                                                                                                                                                  |
| Special-form names           | `if`, `let`, `cond`'s `=>`, etc. cannot be lexically rebound as ordinary variables. The expander dispatches them on the literal symbol before consulting the lexical environment. |
| Macro hygiene                | `(syntax-rules <id> () ...)` custom-ellipsis identifier and `define-syntax` introduced by another macro template are not supported.                                                                          |
| `define-syntax` placement    | Top-level only — a `define-syntax` inside a `(let () ...)` body is rejected.                                                                              |
| `call/cc`                    | Escape-only. A captured continuation invoked after its dynamic extent has ended raises a Schooner error. Multi-shot continuations and `dynamic-wind` re-entry are deferred to v2.0. |
| Parameter objects            | `make-parameter` and `parameterize` are implemented. Calling a parameter with arguments is rejected (Schooner has no mutation, so the implementation-defined "set the parameter's current value" reading is inapplicable); use `parameterize` instead. |
| Primitive errors             | Type / arity / domain errors raised by primitives surface as `Schooner.Primitive.Error` on the Elixir side and are *not* catchable from Scheme `guard` / `with-exception-handler`. Only Scheme-level `(raise ...)` / `(error ...)` enter the handler chain. |
| Libraries shipped (default)  | `(scheme base)`, `(scheme cxr)`, `(scheme char)`, `(scheme inexact)`, `(scheme complex)`, `(scheme case-lambda)`, `(scheme lazy)`, `(scheme write)`, `(scheme read)`. |
| Libraries shipped (opt-in)   | `(scheme time)` via `Schooner.Time` — embedders pass `Schooner.Time.library()` to `Schooner.Environment.new/1`. Not in the default registry so the sandbox stays pure unless wall-clock access is deliberately granted. Also a worked example of the embeddable-library pattern (see [Host Functions](guides/host-functions.md)). |
| Libraries omitted            | `(scheme file)`, `(scheme load)`, `(scheme repl)`, `(scheme process-context)`, `(scheme eval)`, `(scheme r5rs)`.                                          |
| I/O                          | No file ports, no string ports beyond what `(scheme read)` needs internally, no `read-line`. `display` / `write` / `newline` / `write-string` are present in the string-port flavour: they return the rendered text instead of writing to a port. |
