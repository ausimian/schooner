# Running Untrusted Scheme

Schooner is designed for running Scheme scripts you do not
fully trust — config DSLs, user-supplied rules, plugin scripts.
This guide is the safety reference: which entry point to use
for which trust posture, how to bound resource use, what crosses
the host boundary and what doesn't.

## Trust posture: pick your entry point carefully

The `run` and `eval` families differ in **what's in scope when
the script starts**. The naming is the opposite of what reflex
suggests:

| Family | Auto-imports | Trust posture |
| --- | --- | --- |
| `Schooner.run/1`, `run!/1` | every shipped standard library, when the script declares no imports | **Not sandbox-safe** |
| `Schooner.eval/2,3`, `eval!/2,3` | none — bindings come from the env and the script's own `(import ...)` | **Sandbox-safe** |

For untrusted input, **always use `eval/2`**. A script that
declares no imports cannot reach any primitive — even `+` is
unbound:

```elixir
{:error, %Schooner.Eval.Error{}} = Schooner.eval("(+ 1 2)", Schooner.Env.new())
```

To run, the script must declare exactly which libraries it
needs:

```elixir
{:ok, 3} = Schooner.eval("(import (only (scheme base) +)) (+ 1 2)", Schooner.Env.new())

# `sin` is not in scope — the script asked only for `+` from `(scheme base)`,
# and didn't import `(scheme inexact)` at all.
{:error, _} = Schooner.eval("(import (only (scheme base) +)) (sin 0)", Schooner.Env.new())
```

The embedder thus controls the surface, the script controls the
exact bindings it pulls from that surface.

## Locking down which libraries exist

By default, `Schooner.Env.new()` makes every shipped standard
library available for the script to import. To restrict the menu
itself, use `Schooner.Environment.new/1`:

```elixir
env =
  Schooner.Environment.new(
    standard_libraries: [:base, :char]   # only these two are importable
  )

# Script can import (scheme base), but (scheme inexact) is not in the registry.
{:error, %Schooner.Library.NotFoundError{}} =
  Schooner.eval("(import (scheme inexact)) (sin 0)", env)
```

`:standard_libraries` accepts:

- `:default` — every shipped library (the default).
- `:none` — empty registry.
- a list mixing atom shortcuts (`:base`, `:char`, `:inexact`,
  `:complex`, `:cxr`, `:write`, `:read`, `:lazy`, `:case_lambda`)
  and canonical names like `["scheme", "base"]`.

## Resource limits — bound the BEAM, not the interpreter

Schooner does not implement its own CPU / memory counters. The
recommended pattern is to run untrusted scripts inside a
short-lived process bounded by the standard BEAM tools:

```elixir
def run_untrusted(source, env) do
  task =
    Task.Supervisor.async_nolink(
      MyApp.TaskSupervisor,
      fn -> Schooner.eval(source, env) end,
      max_heap_size: %{
        size: 50_000_000,         # ~50 MB heap
        kill: true,
        error_logger: false
      }
    )

  case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
    {:ok, result}      -> result                     # {:ok, value} | {:error, _}
    {:exit, :killed}   -> {:error, :resource_limit}
    nil                -> {:error, :timeout}
  end
end
```

Three knobs are doing the work:

- **`:max_heap_size`** — when the spawned task's heap exceeds
  the cap, the BEAM kills it. A runaway `(make-vector
  1000000000)` allocates a single BEAM tuple, hits the cap, and
  goes down. The host process is unaffected.
- **`Task.yield(task, timeout)`** — bounds wall-clock time. A
  script that loops forever doesn't return on its own; the
  yield window expires and we move to shutdown.
- **`Task.shutdown(task, :brutal_kill)`** — guarantees the task
  is gone after the timeout, even if it was busy executing
  pure Elixir/native code that would not check reductions.

Adjust `max_heap_size` and the yield timeout to whatever
budget makes sense for your workload. The same pattern works
with plain `spawn` + monitoring if you don't want a Task
supervisor.

## What the script can and cannot do

Even with the standard surface fully imported, an `eval/2`
script:

- **Cannot do file I/O.** `(scheme file)`, `(scheme load)`,
  `(scheme repl)`, `(scheme process-context)`, `(scheme eval)`
  are not shipped at all — see [Deviations](deviations.md).
  `(scheme time)` ships as an opt-in host library (`Schooner.Time`)
  and is unreachable until the embedder lists it on
  `Schooner.Environment.new/1`; default sandboxes have no
  wall-clock access.
- **Cannot mutate.** Schooner's value model has no
  destructive operations. `set!`, `set-car!`, `set-cdr!`,
  `string-set!`, `vector-set!`, `bytevector-u8-set!`, record
  mutators, `string-fill!`, `vector-fill!`, `list-set!` are
  not defined.
- **Cannot escape the BEAM process budget.** The host's
  `:max_heap_size` and timeout bounds apply to anything the
  script does inside the eval task.
- **Cannot inspect host data passed through `Schooner.Host.foreign/1`.**
  Foreign values are opaque to Scheme — no constructor, no
  accessor, `write` redacts to `#<foreign>`.

## Host-boundary continuation barrier

A Scheme callback that captures a `call/cc` continuation, then
tries to escape via that continuation **after the host call has
returned**, is unsupported in v1. Schooner's `call/cc` is
escape-only — a continuation invoked outside its dynamic extent
already raises `Schooner.Eval.Error`, and the host-boundary
case fires the same guard.

The practical rule:

> A continuation captured inside a callback is valid only
> within the dynamic extent of the host call that invoked the
> callback. Use `(raise ...)` and `with-exception-handler` for
> long-lived non-local exit instead.

Exceptions cross the host boundary cleanly through the existing
handler stack — see [Host Functions](host-functions.md) for the
patterns.

This rule is forward-compatible with v2.0's first-class
`call/cc`, where it becomes a hard runtime barrier.

## What doesn't cross the host boundary

Some values cannot be marshalled out of Scheme back into idiomatic
Elixir. `Schooner.eval/2` may return them unchanged, but writing
host code that manipulates them is unsupported:

- **Closures** — the captured env carries a process-dictionary
  globals slot, so a closure returned by `eval` is valid only in
  the calling Elixir process. Treat it as a handle, invoke it via
  `Schooner.apply/2`, don't pass it to other processes.
- **Records** — opaque from the host side unless your host code
  knows the type. Use `Schooner.Host.foreign/1` to wrap host data
  you want to pass through Scheme; don't define record types in
  Scheme expecting the host to use them as Elixir structs.
- **Parameters** — the `t:Schooner.Value.parameter_v/0` shape is
  an internal detail. Treat them like closures: invoke via
  `Schooner.apply/2`, don't move across processes.
- **Continuations** — already covered above. Even within v1's
  escape-only model, do not try to capture and re-invoke a
  continuation from outside its original `call/cc` site.

For exposing host data **to** Scheme (the opposite direction),
use `Schooner.Host.foreign/1`. The wrapped term is fully
opaque from the script side and round-trips through any
value-shaped position (variables, pairs, vectors, closures).

## A minimal sandboxed entrypoint

Putting it together — what a host-side wrapper might look like:

```elixir
defmodule MyApp.Sandbox do
  @sandbox_env Schooner.Environment.new(
                 standard_libraries: [:base, :char, :write],
                 pre_imports: [["scheme", "base"]]
               )

  def run(source, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    heap = Keyword.get(opts, :max_heap_size, 50_000_000)

    task =
      Task.async(fn ->
        Process.flag(:max_heap_size, %{size: heap, kill: true, error_logger: false})
        Schooner.eval(source, @sandbox_env)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, value}}    -> {:ok, value}
      {:ok, {:error, error}} -> {:error, {:script, error}}
      {:exit, :killed}       -> {:error, :resource_limit}
      nil                    -> {:error, :timeout}
    end
  end
end
```

The script gets `(scheme base)` for free (the `:pre_imports`),
can additionally import `(scheme char)` or `(scheme write)`, and
runs inside a heap-limited time-bounded Task. Anything else —
file I/O, network, the host's data — is invisible until the
host registers a library that exposes it.
