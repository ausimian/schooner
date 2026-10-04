# Deviations from r7rs-small

Schooner targets r7rs-small but ships a deliberately smaller
surface. This guide documents every intentional gap, with
runnable examples showing the deviation and the workaround.

## No mutation

**Schooner has no destructive operations.** All values are
immutable; recursion is achieved by sharing environment-frame
identity, not by post-construction mutation. The following
r7rs operations are not defined:

- `set!`
- `set-car!`, `set-cdr!`
- `string-set!`, `string-fill!`, `string-copy!`
- `vector-set!`, `vector-fill!`, `vector-copy!`
- `bytevector-u8-set!`, `bytevector-copy!`
- `list-set!`
- Record-type field mutators

```elixir
{:error, %Schooner.Eval.Error{}} =
  Schooner.eval("(import (scheme base)) (define x 1) (set! x 2)", Schooner.Env.new())
```

**Workaround.** Express state as the return value of a function,
or pass it through `letrec` / parameter objects:

```scheme
(import (scheme base))

;; Instead of: (set! x (+ x 1))
;; Pass the new value through:
(define (step x) (+ x 1))
(step 1)            ;; => 2
```

```scheme
(import (scheme base))

;; Rebind a counter for a dynamic extent with a parameter object
(define counter (make-parameter 0))
(define (with-incremented-counter thunk)
  (parameterize ((counter (+ (counter) 1)))
    (thunk)))

(with-incremented-counter (lambda () (counter)))    ;; => 1
```

The "no mutation" constraint is structural — pervasive in the
implementation, not a flag that can be toggled.

## Inexact reals are double-precision only

Schooner's inexact numeric tower is IEEE-754 doubles. There is
no extended-precision float, no flonum mode, no
`(scheme inexact)` extension beyond what r7rs requires.

```scheme
(import (scheme base) (scheme inexact))
(* 0.1 0.1)         ;; => 0.010000000000000002 (the IEEE-754 double answer)
```

If you need higher precision, expose a host function backed by
`Decimal` or `:erlang.float_to_binary/2` with explicit precision.

## Special-form names are only partly rebindable

A variable can be named after a special form or macro keyword:
`(define if 42) if` returns `42`. Schooner does not always honour
such a binding, though:

- The core special forms (`quote`, `quasiquote`, `if`, `lambda`,
  `define`, `define-values`, `begin`, `letrec*`,
  `define-record-type`, `guard`, `define-syntax`, `let-syntax`,
  `letrec-syntax`, and the unsupported `set!`) dispatch on the
  literal symbol. At the head of a form
  they are always the special form, even inside a local binding
  of the same name; the binding is visible only as a variable
  reference.
- A local binding (a `lambda` parameter or `let` variable) of a
  macro keyword such as `when` or `let` shadows the macro, but a
  top-level `define` of the same name does not.
- `syntax-rules` literals, such as `cond`'s `else` and `=>`, match
  by name even where that name is locally bound.

```elixir
# `if` is visible as a variable...
{:ok, 4} =
  Schooner.eval("(import (scheme base)) (let ((if 3)) (+ if 1))", Schooner.Env.new())

# ...but `(if ...)` is still the special form.
{:ok, 1} =
  Schooner.eval(
    "(import (scheme base)) (let ((if (lambda (a b c) 99))) (if #t 1 2))",
    Schooner.Env.new()
  )
```

**Workaround.** Don't name variables after special forms, macro
keywords, or `syntax-rules` literals.

## Macro hygiene gaps

`syntax-rules` works for the standard r7rs cases. The one gap
is the custom-ellipsis identifier: `(syntax-rules <id> () ...)`
is not supported, and Schooner's ellipsis is always `...`.
`define-syntax` placement is covered in the next section.

The standard idioms — `cond`, `case`, `let`, `when`, `unless`,
`and`, `or`, `do`, `letrec`, `parameterize`, `delay`,
`delay-force`, `case-lambda` — are all defined as
`syntax-rules` macros and behave per spec. `letrec` expands to
`letrec*`, so an initializer that refers to an earlier binding
sees its value (`(letrec ((x 1) (y x)) y)` returns `1`). R7RS
calls such a reference an error but does not require
implementations to signal it.

## `define-syntax` is top-level only

```elixir
{:error, _} =
  Schooner.eval("""
    (import (scheme base))
    (let ()
      (define-syntax twice
        (syntax-rules ()
          ((_ e) (begin e e))))
      (twice 'hi))
  """, Schooner.Env.new())
```

`define-syntax` works at the top level. Inside a `(let () ...)`
body it's rejected. **Workaround**: hoist the macro definition
to the top level, or use `let-syntax` / `letrec-syntax` for
locally-scoped macros.

## `call/cc` is escape-only

Continuations captured by `call-with-current-continuation` /
`call/cc` are **single-shot upward only**. Invoking a captured
continuation:

- **Inside its original dynamic extent** → escapes to the
  `call/cc` site, returning the argument as the continuation's
  value. This is the supported case.
- **Outside its original dynamic extent** → raises
  `Schooner.Eval.Error`. This includes the case where a
  callback captures a continuation and the host invokes the
  callback after the original `call/cc` has unwound.

```scheme
(import (scheme base))

;; Escape pattern — supported.
(call/cc (lambda (k) (+ 1 (k 42))))    ;; => 42
```

Multi-shot continuations (`amb`, generators-via-`call/cc`,
yin-yang puzzle) and `dynamic-wind` re-entry semantics are
**deferred to v2.0**. Lifting the restriction will not break v1
scripts that respect it.

**Workaround for long-lived non-local exit**: use `(raise ...)`
and `with-exception-handler` / `guard`. Exceptions cross
arbitrary frames — including host boundaries — without the
escape-only restriction.

```scheme
(import (scheme base))

(guard (e ((string? e) e))
  (let loop ((n 1000000))
    (if (= n 0)
        (raise "exit-from-deep-loop")
        (loop (- n 1)))))
;; => "exit-from-deep-loop"
```

## Parameters cannot be assigned by procedural call

In r7rs, `(make-parameter init)` returns a procedure that, when
called with arguments, has implementation-defined behaviour for
"setting the parameter's current value". Schooner has no
mutation, so this reading is inapplicable; calling a parameter
with arguments is rejected.

```scheme
(import (scheme base))
(define p (make-parameter 1))
(p)             ;; => 1   — zero-arg call returns current value
;; (p 2)        ;; raises — Schooner has no mutation, no parameter assignment.
```

**Workaround**: use `parameterize` to install a new value
within a dynamic extent.

```scheme
(import (scheme base))
(define p (make-parameter 1))
(parameterize ((p 99))
  (p))          ;; => 99
```

## Primitive errors are not Scheme-catchable

Schooner distinguishes two error classes:

1. **Script-level errors** — raised by `(raise ...)` or
   `(error ...)`. These enter the Scheme exception machinery
   and can be caught by `with-exception-handler` / `guard`.
2. **Primitive errors** — raised by built-in primitives for
   type / arity / domain failures. These surface to the **host**
   as `Schooner.Primitive.Error` and are **not** catchable from
   Scheme.

```scheme
(import (scheme base))

;; (car 5) is a primitive type error — not catchable.
(guard (e (#t "caught"))
  (car 5))
;; => raises Schooner.Primitive.Error to the host
```

**Why**: a sandboxed script must not be able to paper over its
own type errors. Treating primitive failures as Scheme
exceptions would let a malicious script silently swallow them
and continue executing in an inconsistent state.

**Workaround for legitimate "ask forgiveness" patterns**: check
the type explicitly before applying the operation, or wrap the
operation in a host primitive that converts host-side failures
to Scheme errors:

```scheme
(import (scheme base))

(if (pair? x)
    (car x)
    'no-car-on-non-pair)
```

## Libraries shipped vs omitted

| Shipped (default registry) | Shipped (opt-in host library) | Omitted |
| --- | --- | --- |
| `(scheme base)` | `(scheme time)` via `Schooner.Time` | `(scheme file)` |
| `(scheme cxr)` |  | `(scheme load)` |
| `(scheme char)` |  | `(scheme repl)` |
| `(scheme inexact)` |  | `(scheme process-context)` |
| `(scheme complex)` |  | `(scheme eval)` |
| `(scheme case-lambda)` |  | `(scheme r5rs)` |
| `(scheme lazy)` |  |  |
| `(scheme write)` |  |  |
| `(scheme read)` |  |  |

The omitted set is intentionally absent: file / process / eval
are host concerns, exposed by **the embedder** via host functions
if and only if they are appropriate for the trust context.

`(scheme time)` *is* shipped, but as a host library (`Schooner.Time`)
that the embedder must opt in to by passing
`Schooner.Time.library()` to `Schooner.Environment.new/1`. Reading
the clock is non-deterministic, so keeping it out of the default
registry keeps the default sandbox pure. The same module doubles as
a worked example of the embeddable-library pattern — see
[Host Functions](host-functions.md).

## I/O is string-port-only

Schooner has no file ports, no console ports, no `read-line`.
The output primitives `display`, `write`, `newline`,
`write-string` are present in their **string-port flavour**:
they return the rendered text instead of writing to a port.

```scheme
(import (scheme base) (scheme write))
(write "hello")     ;; => "\"hello\""   — the rendered text, not side-effecting
(display 42)        ;; => "42"
```

For scripts that need to side-effect, the embedder exposes a
host function (`info`, `log`, `print`) that does the actual
writing.
For print debugging, the embedder can pass in the opt-in
`(schooner debug)` library (`Schooner.Debug`), whose `trace` and
`print` send text to a sink the embedder chooses. See
[Tooling](tooling.md#tracing-and-assertions).

## What this means for migration

Code written for full r7rs implementations most often needs
adjusting in three places:

1. **Anywhere using mutation** — restructure to pure
   transformation, parameters, or `letrec`-style state.
2. **Anywhere relying on multi-shot `call/cc`** — restructure
   to exceptions, or wait for v2.
3. **Anywhere expecting `(scheme file)` / `(scheme load)`** —
   route through host functions provided by the embedder.

Also check the narrower gaps above: special-form names, macro
hygiene, `define-syntax` placement, parameter assignment, and
primitive-error handling.
