# Host Functions

Schooner ships only pure Scheme primitives by default. Anything
that touches the outside world — logging, reading config, looking
up data, talking to a database — comes from **host functions**:
Elixir functions you register as Scheme procedures via
`Schooner.Host.library/1`.

This guide walks the host-function authoring API: building a
library, the conversion helpers that move between Scheme values
and Elixir terms, foreign payloads for opaque host data, the
callback pattern (Scheme → host → Scheme), and how to map errors
between the two sides.

## A first host library

```elixir
defmodule MyApp.SchemeLib do
  alias Schooner.Host

  def lib do
    Host.library(
      name: ["myapp", "log"],
      primitives: [
        {"info", 1, &info/1},
        {"error", 1, &error_/1}
      ]
    )
  end

  defp info([msg]) do
    text = Host.to_string!(msg, op: "myapp/log/info")
    Logger.info(text)
    :unspecified
  end

  defp error_([msg]) do
    text = Host.to_string!(msg, op: "myapp/log/error")
    Logger.error(text)
    :unspecified
  end
end
```

The shape of a host primitive is `{name :: binary, arity ::
Schooner.Value.arity_spec, fun :: ([Schooner.Value.t] ->
Schooner.Value.t)}` — the same ABI used by every built-in
primitive Schooner ships with.

To use the library, list it on `Schooner.Environment.new/1`:

```elixir
env = Schooner.Environment.new(libraries: [MyApp.SchemeLib.lib()])
Schooner.eval!(~s|(import (myapp log)) (info "starting")|, env)
```

Because the library has a non-empty name, it is **named** — the
script must `(import (myapp log))` to see its bindings. That's
the sandbox-safe default: the embedder controls the menu, the
script controls which dishes it orders.

## Anonymous libraries (no import needed)

For trivial cases — a single helper, a constant — a host
library with `name: []` is **anonymous**: its bindings are
applied directly to the runtime env at construction time, with
no `(import ...)` required:

```elixir
inject =
  Schooner.Host.library(
    primitives: [
      {"now-ms", 0, fn [] -> System.system_time(:millisecond) end}
    ]
  )

env = Schooner.Environment.new(libraries: [inject])
Schooner.eval!("(now-ms)", env)
# => some integer
```

There is no Scheme syntax that produces an empty library-name
datum, so anonymous libraries are unreachable from script code;
the only path their bindings enter scope is the embedder
listing them. **This is sandbox-loosening** — list anonymous
libraries deliberately.

## Conversion helpers

Schooner does not auto-marshal across the host boundary. Host
functions consume `Schooner.Value.t/0` and return
`Schooner.Value.t/0`. To go between Scheme values and idiomatic
Elixir terms, use the helpers on `Schooner.Host`.

### Naming convention

- `to_*!/2` — **asserting**: raises `Schooner.Host.TypeError` on
  shape mismatch. Takes a keyword list with `:op` so the error
  points at the host call site.
- `to_*/1` — **total**: returns `{:ok, term} | :error`. Use for
  the "branch on shape" case.

```elixir
# Asserting — the typical case in a host primitive body
text = Host.to_string!(msg, op: "myapp/log/info")

# Total — when a type mismatch is not an error
case Host.to_string(msg) do
  {:ok, text} -> Logger.info(text)
  :error      -> Logger.info(Schooner.Value.write(msg))
end
```

### Avoid `import Schooner.Host`

Several helper names (`to_string`, `to_string!`) shadow
`Kernel.to_string/1`. **Use `alias Schooner.Host`** and call the
helpers as `Host.to_string!(value, op: "...")`. Don't `import`
the module.

### Available accessors

| Helper | Accepts | Returns |
| --- | --- | --- |
| `to_integer!/2` | bare exact integer | Elixir integer |
| `to_float!/2` | bare Elixir float | Elixir float |
| `to_real!/2` | integer / float / rational | Elixir number (rationals coerced to float) |
| `to_string!/2` | bare binary (Scheme string) | Elixir binary |
| `to_symbol_name!/2` | `{:sym, name}` | Elixir binary (the name) |
| `to_char!/2` | `{:char, cp}` | non-negative integer codepoint |
| `to_bool!/2` | `true \| false` | Elixir bool |
| `to_list!/2` | proper Scheme list | Elixir list |
| `to_vector!/2` | `{:vector, tuple}` | Elixir list |
| `to_bytevector!/2` | `{:bytevector, binary}` | Elixir binary |
| `to_foreign_ref!/2` | `{:foreign, term}` | the wrapped host term |
| `to_proc!/2` | closure / primitive / parameter | the value unchanged (callable assertion) |

The `to_real!/2` vs `to_float!/2` split is deliberate:
`to_float!/2` rejects integers (the host should say what it
wants), `to_real!/2` is the lenient "give me whatever number it
is" form.

### Constructors

The same module re-exports `Schooner.Value`'s constructors:
`Host.string/1`, `Host.symbol/1`, `Host.list/1`, `Host.vector/1`,
`Host.foreign/1`, `Host.primitive/3`, etc. Use them instead of
naming the internal tag shape directly — that way future
representation changes only touch `Schooner.Value`, not your
host code.

## Foreign payloads

When the host wants to expose an opaque handle — a `pid`, a
`Reference`, an internal struct — wrap it as a **foreign value**:

```elixir
defmodule MyApp.DbLib do
  alias Schooner.Host

  def lib(db_pid) do
    Host.library(
      name: ["myapp", "db"],
      values: [
        {"connection", Host.foreign(db_pid)}
      ],
      primitives: [
        {"query", 2, &query/1}
      ]
    )
  end

  defp query([conn, sql]) do
    pid = Host.to_foreign_ref!(conn, op: "db/query")
    sql_text = Host.to_string!(sql, op: "db/query")
    rows = MyApp.DB.query(pid, sql_text)
    Host.list(Enum.map(rows, &row_to_scheme/1))
  end

  defp row_to_scheme(row), do: # ...
end
```

Foreign values are **opaque to Scheme**: the script can pass
them around (bind them, return them, store them in pairs and
vectors) but cannot inspect or forge them. `write` redacts the
contents to `#<foreign>`. `eq?` / `eqv?` / `equal?` compare the
wrapped Elixir terms with `===`, so two foreigns wrapping the
same pid are equal.

This is the right vehicle for any "host handle a script needs
to reference but shouldn't see inside".

## Callback pattern (Scheme → host → Scheme)

A host function can receive a Scheme procedure as an argument
and invoke it back via `Schooner.apply!/2`:

```elixir
defp map_over_rows([fun, rows_value]) do
  fun = Host.to_proc!(fun, op: "myapp/map-over-rows")
  rows = Host.to_list!(rows_value, op: "myapp/map-over-rows")

  rows
  |> Enum.map(&Schooner.apply!(fun, [&1]))
  |> Host.list()
end
```

Used from Scheme:

```scheme
(import (myapp util))
(map-over-rows (lambda (row) (cons "got" row)) '(1 2 3))
;; => (("got" . 1) ("got" . 2) ("got" . 3))
```

`Schooner.apply!/2` works on any procedure value — closures,
primitives, parameters. The callback runs in the same Elixir
process as the outer eval, so it inherits the current
exception/parameter state. A `with-exception-handler` installed
in the outer script catches an error raised three frames deep
across two host hops.

### Continuation barrier (documentation-only in v1)

A Scheme callback that captures a `call/cc` continuation, then
escapes via that continuation **after the host call has
returned**, is unsupported. Schooner v1's `call/cc` is
escape-only; a continuation invoked outside its dynamic extent
already raises a structured error, and the host-boundary case
fires the same guard. So the rule is:

> Capture-and-escape across the host boundary is undefined and
> raises `Schooner.Eval.Error`. Use `(raise ...)` and
> `with-exception-handler` for callbacks that need long-lived
> non-local exit — exceptions cross the host boundary cleanly
> through the existing handler stack.

This is forward-compatible with v2.0's first-class `call/cc`,
which will turn the rule into a hard runtime barrier.

## Error mapping

Two failure modes cross the boundary in opposite directions.

### Host raises a Scheme-catchable error

When you want the script's `with-exception-handler` / `guard` to
see the error, raise a Scheme exception via `Schooner.Error`:

```elixir
defp query([conn, sql]) do
  pid = Host.to_foreign_ref!(conn, op: "db/query")
  sql_text = Host.to_string!(sql, op: "db/query")

  case MyApp.DB.query(pid, sql_text) do
    {:ok, rows} ->
      Host.list(Enum.map(rows, &row_to_scheme/1))

    {:error, reason} ->
      raise Schooner.Error,
        value:
          Schooner.Value.error_object(
            :user,
            Host.string("db query failed"),
            [Host.foreign(reason)]
          )
  end
end
```

The script catches it like any other:

```scheme
(guard (e ((error-object? e) (handle-failure e)))
  (query connection "SELECT ..."))
```

### Host-side type errors are not script-catchable

`Schooner.Host.TypeError` (raised by `to_*!/2` helpers) and
`Schooner.Primitive.Error` (raised by built-in primitive type /
arity / domain checks) both surface to the **host**, not to the
script. They bubble out of `Schooner.eval!/2` as Elixir
exceptions, or land in the `{:error, _}` arm of `Schooner.eval/2`.

This is deliberate: a sandboxed script must not be able to paper
over its own type errors. If you want a host primitive to
produce a *script-catchable* failure, use the `Schooner.Error`
pattern above; if you want it to be a host-side bug report,
use `Schooner.Host.TypeError` (which is what the assertion
helpers produce automatically).

## Tying it all together

```elixir
defmodule MyApp.Embed do
  alias Schooner.Host

  def env(db_pid) do
    Schooner.Environment.new(
      standard_libraries: :default,
      libraries: [
        MyApp.SchemeLib.lib(),
        MyApp.DbLib.lib(db_pid)
      ],
      pre_imports: [
        ["scheme", "base"],   # define, length, string-append, number->string ...
        ["myapp", "log"]      # info, error
      ]
    )
  end

  def run_rule(source, db_pid) do
    Schooner.eval(source, env(db_pid))
  end
end
```

A script the host hands to `run_rule/2`:

```scheme
(import (myapp db))
(define rows (query connection "SELECT id FROM users WHERE active = TRUE"))
(info (string-append "got " (number->string (length rows)) " rows"))
rows
```

- `define`, `string-append`, `number->string`, `length` are in
  scope without import (pre-imported `(scheme base)`).
- `info` is in scope without import (pre-imported `(myapp log)`).
- `query` and `connection` are in scope after the explicit
  `(import (myapp db))`.

Decide which surface to pre-import based on trust. For untrusted
input you might lock down the standard libraries to a tighter
set (`standard_libraries: [:base, :char]`) so the script can't
even *attempt* to import things you don't want to expose — see
[Sandbox](sandbox.md).
