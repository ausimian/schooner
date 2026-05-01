# Embedding Schooner

Schooner is a sandboxed Scheme interpreter you embed in an Elixir
application. The host hands a script source to one of the entry
points, gets back an Elixir term, and resource-bounds the work
with the standard process tools. This guide is the five-minute
getting-started — the first script, the value model you'll see on
the way back, and the choice between the available entry points.

## Hello, Schooner

```elixir
{:ok, value} = Schooner.eval("(import (scheme base)) (+ 1 2)", Schooner.Env.new())
value
# => 3
```

The pieces:

- `"(import (scheme base)) (+ 1 2)"` — the Scheme source. The
  `(import ...)` declaration brings `+` into scope; without it
  even the basics are unbound.
- `Schooner.Env.new()` — a fresh environment. Top-level `define`s
  the script makes will land in this env's globals slot and
  persist if you re-use the env for another `eval`.
- `Schooner.eval/2` — read, expand, evaluate. Returns
  `{:ok, value}` on success, `{:error, exception}` for any
  script-level failure.

For the raising variant, use the bang form:

```elixir
3 = Schooner.eval!("(import (scheme base)) (+ 1 2)", Schooner.Env.new())
```

## Choosing an entry point

Schooner's eval entry points come in two flavours, each with a
bang and a tagged-tuple form:

| Family | Auto-imports | Trust posture | Use for |
| --- | --- | --- | --- |
| `Schooner.run/1` and `Schooner.run!/1` | injects every shipped standard library when the script declares none | **Not sandbox-safe.** Every shipped primitive is in scope. | tests, REPL-style use, your own scripts |
| `Schooner.eval/2,3` and `Schooner.eval!/2,3` | none — bindings come exclusively from the env and the script's own `(import ...)` | **Sandbox-safe.** The embedder controls the surface. | embedding scripts you do not control |

Picking the wrong family for untrusted input is a sandbox-shaped
hole. Prefer `eval/2` whenever the script source isn't yours.

## The `Schooner.Environment` shortcut

`Schooner.Env.new()` is the low-level path. For typical embedding
work — registering host libraries, controlling which standard
libraries are reachable — use `Schooner.Environment.new/1`:

```elixir
env =
  Schooner.Environment.new(
    standard_libraries: [:base, :char],   # only these are importable
    libraries: [my_log_lib],              # custom host library
    pre_imports: [["myapp", "log"]]       # auto-imported, no script-side import needed
  )

{:ok, value} = Schooner.eval("(info \"hello\") (+ 1 2)", env)
```

See [Host Functions](host-functions.md) for the host-library
authoring side. The `%Schooner.Environment{}` struct is opaque —
treat it as a handle, not a record to pattern-match against.

## The value model

Scheme values cross the boundary as tagged Elixir terms.
`Schooner.eval/2` returns whatever the script's last form
produced, in this representation:

| Scheme value | Elixir representation |
| --- | --- |
| `#t` / `#f` | `true` / `false` |
| `()` (empty list) | `[]` |
| `(a . b)` (pair) | `[a \| b]` |
| `42` (exact integer) | `42` |
| `1.5` (inexact real) | `1.5` |
| `1/2` (exact rational) | `{:rational, 1, 2}` |
| `+inf.0` / `-inf.0` / `+nan.0` | `{:float_special, :pos_inf \| :neg_inf \| :nan}` |
| `1+2i` (complex) | `{:complex, 1, 2}` |
| `#\a` (character) | `{:char, ?a}` |
| `"hello"` (string) | `"hello"` |
| `'foo` (symbol) | `{:sym, "foo"}` |
| `#(1 2 3)` (vector) | `{:vector, {1, 2, 3}}` |
| `#u8(0 1 255)` (bytevector) | `{:bytevector, <<0, 1, 255>>}` |
| Procedure / closure | `{:closure, ...}` or `{:primitive, name, arity, fun}` |
| Record instance | `{:record, type_id, fields_tuple}` |
| Error object | `{:error_obj, kind, message, irritants}` |
| EOF | `:eof` |
| Unspecified | `:unspecified` |
| Foreign (host opaque) | `{:foreign, term}` |

The strict bare-Elixir representations (integer, float, binary,
list, boolean) are the same shape Elixir uses natively. Tagged
representations exist where Scheme's type discrimination is
finer than the BEAM's — symbols vs strings (both binaries),
characters vs integers, vectors vs records vs closures (all
tuples).

**Don't pattern-match `Schooner.Value` shapes directly in host
code.** Use the conversion helpers in `Schooner.Host` — see
[Host Functions](host-functions.md). They are the seam that
future representation changes pivot on.

## Calling Scheme procedures from Elixir

A script can return a procedure (a closure or a primitive); the
host stashes it and invokes it later via `Schooner.apply/2`:

```elixir
env = Schooner.Environment.new()
{:ok, double} = Schooner.eval("(import (scheme base)) (lambda (x) (* x 2))", env)
{:ok, 42} = Schooner.apply(double, [21])
```

Same pattern works for callbacks — see the host-functions guide.

## Compile once, run many times

For scripts you'll evaluate repeatedly, `Schooner.compile/2`
caches the lex+read+expand work:

```elixir
env = Schooner.Environment.new()
{:ok, compiled} = Schooner.compile("(import (scheme base)) (+ 1 2)", env)

{:ok, 3} = Schooner.run_compiled(compiled, env)
{:ok, 3} = Schooner.run_compiled(compiled, env)
```

The compiled artifact is opaque (`%Schooner.Compiled{}`) — its
internals belong to the evaluator. You can run it against any
`%Schooner.Environment{}` whose macro environment is compatible
with the one passed to `compile`. Variable bindings from the
script's `(import ...)` declarations are pre-resolved and baked
in, so they're guaranteed to be in scope at run time regardless
of the runtime env's registry.

## Error handling

The bare-name entry points return `{:ok, _} | {:error, exception}`.
The exception families that surface as `{:error, _}`:

- `Schooner.Error` — uncaught Scheme `(raise ...)` in the script
- `Schooner.Eval.Error` — runtime evaluation failure
- `Schooner.Primitive.Error` — primitive type / arity / domain error
- `Schooner.Library.NotFoundError` — `(import ...)` of a missing library
- `Schooner.Lexer.Error`, `Schooner.Reader.Error`,
  `Schooner.Expander.Error` — source-level failures

`ArgumentError` raised by malformed options is **not** caught —
that's an embedder bug, not a script-level failure, and
silencing it would hide configuration mistakes.

The bang forms raise the same exceptions directly.

## Next steps

- [Host Functions](host-functions.md) — exposing Elixir as Scheme.
- [Sandbox](sandbox.md) — running untrusted Scheme safely.
- [Deviations from r7rs-small](deviations.md) — every gap, with
  runnable examples.
