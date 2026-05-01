# Schooner — Embeddable Scheme Interpreter

## Status

All 15 phases of the original plan are shipped. The MVP language surface
and embedding API are complete; the project is at a usable v0.1.

| Phase | Subject | Status |
| --- | --- | --- |
| 1 | Project skeleton & value model | shipped |
| 2 | Lexer | shipped |
| 3 | Reader | shipped |
| 4 | Core evaluator MVP | shipped |
| 5 | Arithmetic & predicates | shipped |
| 6 | Pairs, lists, vectors, strings, chars, symbols | shipped |
| 7 | Built-in derived forms (temporary) | shipped (replaced by phase 9) |
| 8 | Internal defines & body splicing | shipped |
| 9 | Hygienic `syntax-rules` expander | shipped |
| 10 | Records | shipped |
| 11 | Exception system | shipped |
| 12 | Escape continuations & dynamic-wind | shipped |
| 13 | Library system & standard library packaging | shipped |
| 14 | Conformance subset & docs | shipped |
| 15 | Embedding API & host injection | shipped |

The phase-by-phase plan below remains as the historical specification.
Phase 15's actual API shape diverged from the sketch — see the
"Phase 15 as shipped" subsection at the end of phase 15 for the
final surface, and the [`guides/`](guides/) directory for narrative
documentation.

## Context

`schooner` is a fresh `mix new` project intended to host an embeddable, sandboxed Scheme interpreter for the BEAM, targeting r7rs-small minus the mutable operations (`set!`, `set-car!`, `set-cdr!`, `string-set!`, `vector-set!`, `bytevector-u8-set!`, record mutators). The intended use is running untrusted or semi-trusted Scheme scripts inside an Elixir application — configuration, rules, user-supplied logic — with the host injecting any procedures the script is allowed to call.

The "no mutation" constraint is a substantial simplification: environments and aggregate values can be pure persistent terms, and `letrec` semantics are handled by tying the knot at construction time rather than via assignment.

## Locked-in architecture decisions

| Concern | Decision |
| --- | --- |
| Control flow | Tail-recursive direct `eval`/`apply` in Elixir. Proper Scheme tail calls fall out of BEAM's last-call optimisation when `eval` and `apply` finish with a tail call to each other. No CPS pass, no trampoline. |
| `call/cc` | Escape-only continuations via Erlang `throw`/`catch`. Multi-shot continuations are out of scope; with no `set!` they are mostly a curiosity anyway. |
| Macros | Full r7rs hygienic `syntax-rules` with ellipsis patterns. Implemented as a dedicated AST→AST expansion pass between the reader and the evaluator. |
| Numeric tower | Erlang integers (arbitrary precision) for exact integers, Erlang floats for inexact reals. Exactness tracked explicitly. No rationals, no complex — operations that require them raise. |
| Sandbox | Default environment exposes only pure r7rs primitives. The embedding API lets the host register Elixir functions as Scheme procedures. CPU/memory limits are delegated to BEAM process facilities (`spawn` + timeout, `max_heap_size`, scheduler reductions) — the interpreter does not implement its own counters. |
| I/O | No port abstraction in the language by default. Host functions are the supported way to do I/O. |

## Value representation (`Schooner.Value`)

All Scheme values map to tagged Elixir terms. Tagging avoids ambiguity (Scheme `#f` vs `'()` vs unspecified, Scheme strings vs bytevectors, Scheme symbols vs strings).

- Booleans: `{:bool, true}` / `{:bool, false}`. Truthiness check: only `{:bool, false}` is false.
- Empty list: `:null`
- Pair: `{:pair, car, cdr}`
- Symbol: `{:sym, binary}` (binaries, not atoms — atoms aren't GC'd and the table is bounded; a sandboxed script must not be able to fill it)
- String: `{:string, binary}`
- Char: `{:char, codepoint}`
- Exact integer: plain Elixir integer
- Inexact real: plain Elixir float
- Vector: `{:vector, tuple}`
- Bytevector: `{:bytevector, binary}`
- Closure: `{:closure, params, body, env, name_or_nil}`
- Primitive: `{:primitive, name, arity, fun}`
- Record instance: `{:record, type_id, fields_tuple}`
- Eof: `:eof`
- Unspecified: `:unspecified`

A `to_iodata/1` for `display`/`write` lives next to the value module.

## Module layout

```
lib/schooner.ex                  # public embedding API
lib/schooner/value.ex            # value model, predicates, write/display
lib/schooner/lexer.ex            # source string → token stream
lib/schooner/reader.ex           # token stream → datum AST
lib/schooner/expander.ex         # datum AST → core AST (macro expansion)
lib/schooner/expander/syntax_rules.ex
lib/schooner/env.ex              # immutable environments, frame chains
lib/schooner/eval.ex             # tail-recursive eval/apply
lib/schooner/primitives/         # one module per (scheme ...) library
  base.ex
  cxr.ex
  char.ex
  inexact.ex
  case_lambda.ex
  lazy.ex
  read.ex
  write.ex
lib/schooner/library.ex          # define-library / import / export wiring
lib/schooner/host.ex             # host function registration + value marshalling
lib/schooner/error.ex            # exception objects, raise/guard machinery
test/                            # mirrors lib/, plus test/conformance/
```

## Implementation phases

Each phase ends with `mix precommit` green and a runnable demo through the embedding API.

### Phase 1 — Project skeleton & value model

- Add deps: `:stream_data` (test-only), `:nimble_options` (embedding API option validation).
- Set `@version` and `@source_url` module attributes per build conventions.
- Implement `Schooner.Value` with constructors, type predicates, `equal?` / `eqv?` / `eq?`, `display` / `write` rendering.

**Tests:**

- Unit: every constructor and type predicate.
- Unit: `eq?` / `eqv?` / `equal?` on representative pairs covering r7rs semantics (numbers across exactness, strings, symbols, pairs, vectors, records-of-same-type, closures).
- Unit: `write` and `display` rendering of every value tag, including nested structures and edge cases (empty list, dotted pairs, escaped characters in strings, reserved characters in symbols).
- Property (stream_data): generators for every value tag, used to assert structural invariants (e.g. `equal?(v, v)` for any generated `v`).
- Stub property test for the write→read round-trip — marked `@tag :skip` until phase 3 lands the reader.

### Phase 2 — Lexer (`Schooner/lexer.ex`)

- Hand-rolled lexer over a binary cursor. Tokens: open/close paren, vector-open `#(`, bytevector-open `#u8(`, quote `'`, quasiquote `` ` ``, unquote `,`, unquote-splicing `,@`, dot `.`, identifier, number, string literal, char literal, boolean, comment (line `;`, block `#|...|#`, datum `#;`).
- Source positions (line, column) on every token.
- Defer datum labels (`#0=` / `#0#`) — without mutation, true cycles are unreadable anyway.

**Tests:**

- Unit: each token type with valid inputs (positive cases) and several invalid inputs (negative cases producing structured errors).
- Unit: comments — line, nested block (`#| outer #| inner |# outer |#`), datum-comment skipping.
- Unit: numeric prefixes (`#e`, `#i`, `#b`, `#o`, `#d`, `#x`) in every legal combination, including negatives and exactness mismatches.
- Unit: string literals with escape sequences (`\n`, `\t`, `\"`, `\\`, hex `\xHH;`).
- Unit: char literals — named (`#\space`, `#\newline`), hex (`#\x41`), and direct (`#\a`).
- Unit: identifiers including the surprising r7rs cases (peculiar identifiers like `+`, `-`, `...`, vertical-bar-quoted `|hello world|`).
- Unit: source position assertions on multi-line input — every token's line/column matches expectation.
- Property: lexing then re-emitting trivial tokens (numbers, identifiers without escapes) round-trips.

### Phase 3 — Reader (`Schooner/reader.ex`)

- Token stream → datum AST built from `Schooner.Value` cons cells.
- Desugar reader macros: `'x` → `(quote x)`, `` `x `` → `(quasiquote x)`, `,x` → `(unquote x)`, `,@x` → `(unquote-splicing x)`.
- Handle dotted pairs, vector literals, bytevector literals, numeric prefixes (`#e`, `#i`, `#b`, `#o`, `#d`, `#x`).
- Errors carry source position and a span.

**Tests:**

- Unit: every datum kind read into the expected `Schooner.Value` representation (atoms, lists, dotted pairs, vectors, bytevectors, all quote forms, every literal type).
- Unit: parse-error cases with explicit source-position assertions (unmatched paren, dot in wrong position, unterminated string, invalid `#u8` byte, unterminated block comment).
- Unit: nested data — vectors inside lists inside quasiquote inside lists.
- Property: write→read round-trip — generate any `Schooner.Value` (excluding closures and primitives), `write` it, read it back, assert `equal?`. **This is the closing test for the lex/read layer.** Unskip the property test stubbed in phase 1.

### Phase 4 — Core evaluator MVP (`Schooner/eval.ex`, `Schooner/env.ex`)

The smallest evaluator that runs. Recognises only the **core** special forms:

`quote`, `if`, `lambda`, `define` (top-level only), `begin`, application, variable reference.

- `Env` is a list of immutable frames; lookup walks frames; `define` extends the top frame.
- `eval/2` and `apply/2` are mutually tail-recursive: every branch ends with a tail call to `eval` or `apply`, never wrapped in a tuple, `try`, or anything else that would break BEAM TCO. This is invariant #1 — comment it at the top of `eval.ex` and add a test that recurses 100k deep.
- `letrec`-style mutual recursion (needed even at this stage for primitives that close over the env): bind a frame whose closure values reference the *frame* by identity, not by value-at-bind-time, so all names resolve once the frame is fully populated.

**Tests:**

- Unit: each core form — `quote` returns datum unchanged, `if` selects branch on truthiness (only `#f` is false), `lambda` produces a closure, `define` extends the top frame, `begin` returns last form's value.
- Unit: lexical scoping — inner binding shadows outer; closures capture their defining environment, not the calling one.
- Unit: application errors — calling a non-procedure raises a structured error; arity mismatch raises with a clear message.
- **TCO regression**: a lambda calling itself in tail position 100 000 times completes without growing the BEAM stack (assert via `Process.info(self(), :total_heap_size)` not exploding, or simply that the test returns).
- **TCO regression**: tail call in the chosen branch of `if`, in the last form of `begin`, and in the body of an applied lambda — three separate tests, each at 100k depth.
- **TCO regression**: mutually tail-recursive Scheme functions (`even?` / `odd?` style) at 100k depth.

### Phase 5 — Arithmetic & predicates

- `(scheme base)` numeric core: `+ - * /`, `quotient`, `remainder`, `modulo`, `abs`, `min`, `max`, comparison, `expt` (integer cases), `gcd`, `lcm`.
- Exactness rules: any inexact operand contaminates the result. `exact->inexact`, `inexact->exact` (the latter only for floats representable exactly).
- Predicates: `number?`, `integer?`, `exact?`, `inexact?`, `zero?`, `positive?`, `negative?`, `odd?`, `even?`, plus type predicates for every value tag.
- `not`, `boolean?`, `boolean=?`.
- Operations that would require rationals or complex (`sqrt` of a non-square integer, `/` producing a non-integer with exact operands) raise a documented error.

**Tests:**

- Unit: each arithmetic op evaluated on (exact, exact), (exact, inexact), and (inexact, inexact) operand pairings — exactness contamination rule is the assertion.
- Unit: arbitrary-precision integers — `(* 10000000000 10000000000)` returns an exact integer, never overflows.
- Unit: float edge cases — division by zero, `nan`, `+inf.0`, `-inf.0` round-trip through write/read correctly.
- Unit: every predicate, exhaustively over a fixture of values covering each value tag (table-driven).
- Unit: documented "raises on rationals/complex" errors — `(/ 1 3)` with exact operands, `(sqrt 2)`, and similar each raise with a Schooner-specific error type the test asserts on.
- Property: associativity and commutativity of `+` and `*` on small integers; identity element; `(- a b)` = `(+ a (- b))`.

### Phase 6 — Pairs, lists, vectors, strings, chars, symbols

All immutable.

- Pairs: `cons`, `car`, `cdr`, `pair?`, `null?`, `list?`, `length`, `reverse`, `append`, `list-tail`, `list-ref`, `member` family, `assoc` family, `map`, `for-each`.
- `(scheme cxr)`: `caar` … `cddddr`.
- Vectors: `vector`, `make-vector` (no fill mutation, just construct), `vector-length`, `vector-ref`, `vector->list`, `list->vector`, `vector-map`, `vector-for-each`, `vector-copy` (returns a new vector), `vector-append`.
- Bytevectors: `bytevector`, `bytevector-length`, `bytevector-u8-ref`, `utf8->string`, `string->utf8`.
- Strings: `string`, `make-string`, `string-length`, `string-ref`, `string-append`, `substring`, `string=?`, `string<?` family, `string->list`, `list->string`, `string-upcase`, `string-downcase`, `string-copy`.
- Chars (`(scheme char)`): codepoint-based comparators, case mappings, predicates. Use Elixir's `:unicode` / `String` modules.
- Symbols: `symbol?`, `symbol=?`, `symbol->string`, `string->symbol`.

**Tests:**

- Unit: each list operation against fixtures including empty list, single-element, long, and improper-list inputs (where applicable).
- Unit: vector ops, including the immutability guarantee — `vector-copy` returns a vector that is `equal?` but not `eq?` to its source.
- Unit: string ops with multi-byte UTF-8 inputs (combining characters, surrogates expressed as codepoints, BMP/non-BMP boundaries).
- Unit: char ops with Unicode case-mapping fixtures (lowercase ß, Turkish dotless i — known case-mapping land mines).
- Unit: symbol identity rules — `(eq? (string->symbol "foo") (string->symbol "foo"))` is `#t`.
- Property: list/vector round-trip — `(list->vector (vector->list v))` equals `v`; analogous string/list round-trip.
- Property: list operations preserve length where expected (`reverse`, `map`).

### Phase 7 — Built-in derived forms (temporary)

Until the macro expander lands, implement `cond`, `case`, `when`, `unless`, `and`, `or`, `let`, `let*`, `letrec`, `letrec*`, `do`, named `let`, `quasiquote` directly in the evaluator. This is explicitly throwaway — phase 9 deletes most of it.

Reason for not waiting: it lets phases 5/6 be exercised with realistic Scheme code (test fixtures from real r7rs examples) before the macro layer is in place.

**Tests:**

- Unit: each derived form against r7rs reference behaviour, including edge cases — `cond` with `=>`, `case` with multi-element key clauses and `else`, `and`/`or` short-circuit and return-value semantics, `let` shadowing, `letrec*` left-to-right binding order, `do` step expressions, named `let` recursion (factorial, fibonacci).
- Unit: quasiquote with nested unquote, unquote-splicing into list and into nested quasiquote, splicing of empty lists.
- **These tests are kept verbatim through phase 9** and re-run after the expander replaces these forms — the assertion that the macroified versions behave identically.

### Phase 8 — Internal defines & body splicing

- Body of `lambda` / `let` / etc. with internal `define`s desugars to `letrec*`.
- Implement the "tying the knot" pattern in `Schooner.Env`: a `letrec*` frame is constructed once, and closure values capture the frame by reference so forward references resolve when invoked.
- Address the rec-frame lifecycle leak introduced in phase 7. The current implementation (`Env.extend_rec/2`) backs each rec frame with a process-dictionary slot keyed by `make_ref()` and never deletes it; the slot only goes away when the owning process exits. Recommended embedding pattern (spawn-per-eval) bounds this in practice, but a long-running host that runs many `letrec`/`letrec*`/named-`let` forms in one process accumulates orphan slots. Phase 8 either (a) routes cleanup through the body's tail-call return path without breaking the TCO invariant in `eval.ex`, or (b) replaces mutable rec frames with a non-mutating alternative (e.g. capturing an env-thunk in closures and resolving lazily). Option (b) is preferred because it removes the leak entirely; option (a) is a smaller change with the same observable effect.

**Tests:**

- Unit: internal `define` in a `lambda` body, in a `let` body, in a `cond` clause body — all desugar correctly.
- Unit: mutual recursion via internal defines (two functions defined back-to-back call each other).
- Unit: r7rs constraint — `define` after a non-define expression in the same body is a syntax error.
- Unit: forward reference within `letrec*` — a closure body can name a binding declared later in the same frame.
- Unit: `letrec*` evaluation order — bindings are evaluated left to right; forward reference to an as-yet-unevaluated init from within an init is a runtime error.

### Phase 9 — Hygienic `syntax-rules` expander

The largest single phase. Approach: classic Kohlbecker / Clinger / Rees alpha-renaming with marks on identifiers. References for the implementer:

- Dybvig, *Syntactic Abstraction in Scheme*
- The expander used in Chibi-Scheme is a good simplicity reference.

Steps:

1. Define the **core language** the evaluator accepts: `quote`, `if`, `lambda`, `define`, `begin`, application, variable. Everything else is a macro.
2. Pattern matcher for `syntax-rules` patterns including ellipsis (`...`), nested ellipsis, literals, and `_` wildcard.
3. Template instantiator with hygienic identifier renaming (each introduced identifier gets a fresh mark; references resolve via mark + binding-time environment).
4. `define-syntax`, `let-syntax`, `letrec-syntax`.
5. Re-express derived forms from phase 7 as `syntax-rules` macros in `lib/schooner/primitives/derived.scm` (loaded as part of the standard library boot). Delete the throwaway evaluator branches.

Acceptance: classic torture tests — `cond` with `=>`, `case`, `or`, `let` with shadowing of the macro's own keyword, mutually recursive macros, ellipsis under nested ellipsis.

**Tests:**

- Unit: pattern matcher in isolation — literal patterns, ellipsis, nested ellipsis (`((a b) ...)`, `(a ... b)`), `_` wildcard, dotted patterns, vector patterns.
- Unit: template instantiator in isolation — splicing ellipsis-bound vars, free identifiers preserved, scope of pattern variables.
- Unit: hygiene — a macro that introduces `(let ((x ...)) ...)` does **not** capture a user `x` at the call site; conversely, a user-supplied identifier passed into a macro template does not bind the macro's own internals.
- Unit: classic torture cases — `or` defined as a macro shadowing the built-in, `cond` with `=>`, mutually recursive macros via `letrec-syntax`.
- **Regression**: phase 7's full derived-form test suite re-runs unchanged with the macroified implementation. Failure here means the macro layer differs from the throwaway implementation.
- Unit: `define-syntax`, `let-syntax`, `letrec-syntax` — scoping of macro bindings.

### Phase 10 — Records

`define-record-type` with constructor, predicate, and field accessors. **No** field mutators (skipped per the no-mutation constraint).

Records as `{:record, type_id, fields_tuple}`. Type IDs are gensyms generated at expansion time so two `define-record-type` forms with the same name in different scopes are distinct.

**Tests:**

- Unit: constructor returns a record; predicate is `#t` for own type, `#f` for everything else (including records of a different type with the same field shape).
- Unit: each accessor returns the correct field; accessor on wrong record type raises.
- Unit: two `define-record-type` forms with the same name in different lexical scopes produce distinct types — predicates do not cross-recognise.
- Unit: records nested inside lists, vectors, and other records `equal?`-compare structurally.
- Unit: `write` rendering for a record is unambiguous and round-trippable through `read` only if the script re-defines the type (documented limitation).

### Phase 11 — Exception system

- Exception objects: `error-object?`, `error-object-message`, `error-object-irritants`, `error-object-irritants`, `error?`, `read-error?`, `file-error?`.
- `raise`, `raise-continuable`, `error`.
- `with-exception-handler`, `guard`.
- Implementation: handler stack threaded through the evaluator. `raise` walks the stack; if no handler matches, the host gets a structured Elixir exception (`Schooner.Error`).

**Tests:**

- Unit: `raise` inside `with-exception-handler` invokes the handler with the raised object.
- Unit: `guard` with several clauses dispatches on predicate; falls through to outer handler if none match.
- Unit: `error-object?` / `error-object-message` / `error-object-irritants` accessors.
- Unit: an unhandled `raise` in a script propagates to the host as a `Schooner.Error` with the original irritants attached.
- Unit: handler installed on a deeply nested tail call is reached without the stack growing — exception propagation must coexist with TCO.

### Phase 12 — Escape continuations & dynamic-wind

- `call-with-current-continuation` / `call/cc` returns a single-use escape procedure implemented via a fresh `throw` tag and a top-level `catch` reinstalled at each `call/cc` site. Invoking the procedure throws; the matching `catch` returns its argument as the value of the original `call/cc` call.
- `dynamic-wind`: maintain a wind stack. On every escape (continuation invocation, exception raise, normal return out of a `dynamic-wind`), compute the difference between current and target wind stacks and run the appropriate `before` / `after` thunks.
- Document explicitly: continuations are single-shot upward only. Calling a continuation after its dynamic extent has ended raises a Schooner-specific error.
- **Forward-compatibility note.** The single-shot restriction is intentionally a documented error rather than undefined behaviour — full first-class `call/cc` is planned for v2.0 (see "Deferred to v2.0" below). Lifting an error case is non-breaking, so v1 scripts that respect the restriction will continue to work unchanged on v2.

**Tests:**

- Unit: `(call/cc (lambda (k) (+ 1 (k 42))))` returns `42`.
- Unit: `call/cc` as early return from a deep loop.
- Unit: `dynamic-wind` ordering — `before` runs on entry, `after` runs on normal exit.
- Unit: `dynamic-wind` interaction with escape — invoking a continuation that crosses a `dynamic-wind` boundary fires the appropriate `after` thunk.
- Unit: invoking a continuation after its dynamic extent has ended raises a documented Schooner error (this is the explicit deviation from spec; the test pins it).
- Unit: `dynamic-wind` interaction with `raise` — `after` thunks fire when an exception escapes a `dynamic-wind`.

### Phase 13 — Library system & standard library packaging

- `define-library`, `import`, `export`, `cond-expand`, `include`, `include-library-declarations`.
- Ship: `(scheme base)`, `(scheme cxr)`, `(scheme char)`, `(scheme inexact)`, `(scheme case-lambda)`, `(scheme lazy)` (delay/force/make-promise), `(scheme write)`, `(scheme read)` (string-port flavour only).
- Explicitly omitted: `(scheme file)`, `(scheme load)`, `(scheme repl)`, `(scheme process-context)`, `(scheme time)` (host-injectable instead), `(scheme eval)`, `(scheme complex)`, `(scheme r5rs)`.

**Tests:**

- Unit: `define-library` declaring exports / `import` consuming them across two source files.
- Unit: `import` modifiers — `only`, `except`, `prefix`, `rename` each behave per spec.
- Unit: `cond-expand` selects the active branch based on registered features.
- Unit: every shipped library exposes exactly its r7rs-specified bindings (table-driven test enumerating expected exports per library).
- Unit: importing a non-existent library produces a clear error pointing at the offending `import` form's source position.

### Phase 14 — Conformance subset & docs

- Curate a subset of the Chibi-Scheme test suite covering the implemented surface; commit as `test/conformance/`.
- README documents the deviations from r7rs-small in one table: no mutation, no rationals, no complex, escape-only `call/cc`, no file I/O, host-controlled environment.

**Tests:**

- Conformance: curated Chibi tests run as a single ExUnit case per source file under `test/conformance/`. Every excluded test is documented inline with a one-line reason (skipped because of mutation / numeric tower / multi-shot call/cc / etc.). Driven through `Schooner.run/1` (the same entry point used by the existing eval tests) so this phase has no dependency on the Phase 15 embedding API.
- Doc test: README code examples are exercised via ExUnit doctests once Phase 15 lands and the README's embedding examples exist; for now, the conformance suite stands alone.

### Phase 15 — Embedding API & host injection (`Schooner`, `Schooner.Host`)

```elixir
{:ok, env} =
  Schooner.Environment.new(
    libraries: [:base, :char, :inexact, :lazy],
    host_functions: [
      {"now-ms", 0, fn [] -> System.system_time(:millisecond) end},
      {"log",    1, fn [msg] -> Logger.info(inspect(msg)); :unspecified end}
    ]
  )

{:ok, value} = Schooner.eval_string("(+ 1 (now-ms))", env)
```

- `Schooner.compile/1` produces a fully expanded core AST for caching. The returned term is **opaque** (wrap as `%Schooner.Compiled{}` or document "treat as opaque") — embedders must not pattern-match on its internals. This is the seam that lets the v2.0 evaluator rewrite swap representations without breaking the public API.
- `Schooner.Host` defines the marshalling rules: Scheme `{:string, b}` ↔ Elixir binary, lists ↔ lists, integers/floats unwrapped, vectors ↔ tuples, symbols stay tagged. Anything not representable raises a marshalling error at the boundary. **Closures, records of host-unknown types, and continuations are explicitly not marshallable** — listing continuations now (even though v1's escape-only continuations cannot meaningfully cross the boundary) makes the rule stable across the v2.0 multi-shot upgrade.
- **Host-boundary continuation barrier.** A Scheme procedure invoked from a host function executes inside a continuation barrier: capturing a continuation across the boundary and invoking it after the host call has returned is a Schooner error. Under v1's escape-only model this case is unreachable, so the rule is documentation-only; under v2.0's first-class `call/cc` it becomes load-bearing. Documenting it in v1 keeps v2 from having to introduce a new error case retroactively.
- The host is responsible for resource limits — document the recommended pattern (run `Schooner.eval/2` inside a spawned process with `:max_heap_size` and a timeout `:after`).

**Tests:**

- Unit: `Schooner.eval_string/2` happy path returning each major value type, asserted against the expected Elixir-side representation.
- Unit: `Schooner.compile/1` produces a reusable AST — same compiled form evaluated against two different environments produces independent results.
- Unit: a registered host function called from Scheme receives correctly marshalled arguments and its return value is correctly marshalled back.
- Unit: marshalling errors at the boundary surface as a structured Elixir exception — closures, records of unknown type, and other non-marshallable values are rejected with a clear message.
- Unit: a script calling an unregistered procedure errors with "unbound variable: name" pointing at the source position.
- Integration: `Task.async/Task.await` running `Schooner.eval/2` with a low `:max_heap_size` is killed cleanly when a runaway script allocates beyond the budget — host process is unaffected.
- Integration: a script that loops forever is killed by `Task.shutdown/2` with a timeout — host process is unaffected.

### Phase 15 as shipped

The phase-15 sketch above predated the design conversation that
produced the actual surface. Recording what landed, since it
diverged in several places worth pinning:

**Sub-phase order (5 PRs, all merged):**

- 15.1 — `Schooner.Host` conversion helpers + `Schooner.Host.TypeError`
- 15.2 — `Schooner.Host.library/1` builder + relaxed `Library.validate_name!/1` to accept `[]`
- 15.3 — `%Schooner.Environment{}` opaque struct + bang/tagged-tuple split for `eval`/`run`
- 15.4 — `Schooner.apply/2`, `compile/2`, `run_compiled/2`, `%Schooner.Compiled{}`
- 15.5 — ExDoc + four guides under `guides/`

**Final API shape:**

- **No auto-marshalling.** Host functions retain the primitive ABI —
  `fn ([Schooner.Value.t()]) -> Schooner.Value.t()`. Conversion is
  explicit via `Schooner.Host.to_*!/2` (asserting, raise
  `TypeError`) and `to_*/1` (total, return `{:ok, _} | :error`).
  The named accessors are the seam future representation changes
  pivot on.
- **Library injection unified on `Schooner.Library`.** A host
  library built via `Schooner.Host.library/1` is the same shape
  as a standard library. **Named** libraries (e.g. `["myapp",
  "log"]`) join the registry; the script must `(import ...)` to
  reach them. **Anonymous** libraries (`name: []`) bypass the
  registry and have their bindings auto-applied to the runtime
  env. There is no separate `:host_functions` / `:inject` option.
- **`%Schooner.Environment{}`** opaque struct bundles env +
  syntax env + registry. `Environment.new/1` options:
  `:standard_libraries` (`:default | :none | list`),
  `:libraries`, `:pre_imports`.
- **Bang/tagged-tuple split** following Elixir convention.
  `Schooner.eval/2,3` and `Schooner.run/1` return `{:ok, _} |
  {:error, exception}`; `eval!/2,3` and `run!/1` raise. Same
  pattern for `apply/2`, `compile/1,2`, `run_compiled/2`.
  `ArgumentError` on bad options propagates — that's an embedder
  bug, not a script-level failure.
- **`compile/2` Option A** — macros are expanded at compile time
  against the supplied environment's syntax env; runtime variable
  bindings the imports resolved to are pre-resolved and baked
  into the `%Compiled{}` artifact. Same artifact runs against
  any compatible `Environment` — host primitives can vary
  between runs without recompilation.
- **Continuation barrier docs-only.** Phase 12's existing
  expired-continuation guard already raises a structured error
  for the host-boundary case; the rule is documented in
  `guides/host-functions.md` and `guides/sandbox.md`, no extra
  enforcement code in v1.

**Documentation:** `guides/embedding.md` (5-minute getting
started + value model + entry-point chooser),
`guides/host-functions.md` (host library authoring, conversion
helpers, foreign payloads, callback patterns, error mapping),
`guides/sandbox.md` (trust posture, resource limits, what
crosses the boundary), `guides/deviations.md` (every gap from
r7rs-small with runnable examples).

## Critical invariants (call out at top of relevant files)

1. **`eval/2` and `apply/2` MUST end every branch with a direct tail call to one of them.** No wrapping `try`, no `case` on the result, no tuple construction around the recursive call. Violating this breaks proper tail calls. (`lib/schooner/eval.ex`)
2. **No assignment anywhere in the value model.** Recursion is achieved by sharing environment-frame identity, not by post-construction mutation. (`lib/schooner/env.ex`)
3. **Symbols are binaries, not atoms.** Never call `String.to_atom/1` on user input. (`lib/schooner/value.ex`, `lib/schooner/reader.ex`)
4. **The core language consumed by `eval` is closed.** New surface forms become macros, not new evaluator branches. After phase 9, additions to `eval.ex` should be very rare. (`lib/schooner/eval.ex`)

## Verification

The primary verification is the per-phase test suite called out in each phase above. Cross-cutting acceptance gates:

- `mix precommit` (compile-warn-as-errors, format, credo --strict, test) green at end of every phase. Never advance to the next phase with red tests.
- Test files live alongside the code they cover (`test/schooner/eval_test.exs` for `lib/schooner/eval.ex`, etc.). Conformance and integration tests live under `test/conformance/` and `test/integration/`.
- Each phase's tests are kept and run as a regression suite by all subsequent phases. Phase 7's derived-form tests survive into phase 9 explicitly to verify the macroified replacement matches the throwaway implementation.
- TCO regressions (phase 4's 100k-depth tests) are re-run after every phase that touches `eval.ex`. Loss of TCO is a release-blocker.

## Out of scope (explicitly)

- Mutation: `set!`, `set-car!`, `set-cdr!`, `string-set!`, `vector-set!`, `bytevector-u8-set!`, record-type mutators.
- Numeric tower beyond integer/float exactness tags.
- File I/O, the port abstraction, `(scheme file)`, `(scheme load)`, `(scheme repl)`, `(scheme process-context)`, `(scheme eval)`, `(scheme complex)`, `(scheme r5rs)`.
- Datum labels in the reader.
- A REPL binary. (Easy follow-up if wanted, but not core.)

### Deferred to v2.0

Items intentionally not in v1 but planned as a future major-version change. v1 documents and tests the restricted behaviour so that lifting the restriction in v2 is non-breaking for embedders who respected the v1 contract.

- **Full first-class `call/cc`.** Multi-shot continuations, re-entry after the original `call/cc` has returned, and `dynamic-wind` re-entry semantics (`before` thunks fire on re-entry, not just `after` on escape). Requires replacing the direct mutual-tail-call evaluator with either a CPS transform or an explicit-continuation-frame trampoline, plus host-boundary barrier enforcement (the documentation-only rule from phase 15 becomes load-bearing).

## Follow-ups after MVP

- `/adopt-build-conventions` to wire `mix.exs`, CI, RELEASE.md, CHANGELOG.md to the org build conventions.
- Performance pass: bind-time variable resolution (de Bruijn indices or precomputed lookup paths), primitive inlining, constant folding during expansion.
- Optional: a minimal `(scheme time)` and `(scheme eval)` exposed only when the host opts in.
- Optional: source-mapped error traces from `eval` back to original reader positions.
- **v2.0: full first-class `call/cc`.** Evaluator rewrite to CPS or explicit-continuation-frame trampoline; multi-shot continuations; `dynamic-wind` re-entry firing `before` thunks on re-entry; host-boundary barrier enforcement (turn the v1 documentation-only rule into a runtime check); new test surface — generators, `amb`, yin-yang puzzle, captured-continuation-loop OOM regression, captured-continuation interaction with `with-exception-handler`. Re-run all phase 4 TCO regressions under the new evaluator shape.
