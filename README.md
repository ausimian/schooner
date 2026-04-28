# Schooner

An embeddable, sandboxed Scheme interpreter for the BEAM, targeting the
r7rs-small language minus its mutable operations. Schooner is intended as
a scripting layer for Elixir applications: hosts hand a script source to
`Schooner.run/1`, get back an Elixir term, and resource-bound the work
with the standard process tools (`:max_heap_size`, `Task.shutdown/2`).

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `schooner` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:schooner, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/schooner>.

## Deviations from r7rs-small

Schooner targets r7rs-small but deliberately ships a smaller surface.
The table below summarises every intentional gap; conformance tests
under `test/conformance/` cover the surface that *is* shipped, with
each excluded upstream case annotated inline.

| Area                         | Schooner                                                                                                                                                  |
| ---                          | ---                                                                                                                                                       |
| Mutation                     | None. `set!`, `set-car!`, `set-cdr!`, `string-set!`, `vector-set!`, `bytevector-u8-set!`, record mutators, `string-fill!`/`copy!`, `vector-fill!`/`copy!`, `list-set!` are not defined. |
| Numeric tower                | Integer + double-precision float only. No rationals (`6/10`), no complex (`3+4i`), no `exact`/`inexact` coercion procedures, no `digit-value`.            |
| Object identity              | `eq?` / `eqv?` reduce to structural equality on pairs, vectors, and strings — there is no mutable cell identity. `memq` / `assq` follow the same rule.    |
| Special-form names           | `if`, `let`, `cond`'s `=>`, etc. cannot be lexically rebound as ordinary variables. The expander dispatches them on the literal symbol before consulting the lexical environment. |
| Macro hygiene                | `(... ...)` ellipsis-escape, `(syntax-rules <id> () ...)` custom-ellipsis identifier, `(syntax-rules (_) ...)` literal-underscore, and `define-syntax` introduced by another macro template are not supported. |
| `define-syntax` placement    | Top-level only — a `define-syntax` inside a `(let () ...)` body is rejected.                                                                              |
| `call/cc`                    | Escape-only. A captured continuation invoked after its dynamic extent has ended raises a Schooner error. Multi-shot continuations and `dynamic-wind` re-entry are deferred to v2.0. |
| Letrec closure escape        | A closure created inside a `letrec` / `letrec*` / named `let` cannot recurse after escaping its frame; the rec frame does not survive. The mutation-free model rules out classical letrec via post-hoc assignment. |
| Multi-value returns          | `values`, `call-with-values`, `define-values`, `let-values`, `let*-values` are not implemented.                                                           |
| Parameter objects            | `make-parameter` and `parameterize` are not implemented.                                                                                                  |
| Primitive errors             | Type / arity / domain errors raised by primitives surface as `Schooner.Primitive.Error` on the Elixir side and are *not* catchable from Scheme `guard` / `with-exception-handler`. Only Scheme-level `(raise ...)` / `(error ...)` enter the handler chain. |
| Libraries shipped            | `(scheme base)`, `(scheme cxr)`, `(scheme char)`, `(scheme inexact)`, `(scheme case-lambda)`, `(scheme lazy)`, `(scheme write)`, `(scheme read)`.        |
| Libraries omitted            | `(scheme file)`, `(scheme load)`, `(scheme repl)`, `(scheme process-context)`, `(scheme time)`, `(scheme eval)`, `(scheme complex)`, `(scheme r5rs)`.    |
| I/O                          | `display` only. No file ports, no string ports beyond what `(scheme read)` needs internally, no `newline` / `read-line` / `write-string`.                |
