defmodule Schooner do
  @moduledoc """
  An embeddable, sandboxed Scheme interpreter for the BEAM, targeting
  the r7rs-small language minus its mutable operations.

  The pipeline is Lexer → Reader → Expander → Eval. The
  `Schooner.Value` module provides the tagged-term value model and
  `Schooner.Env` the immutable-with-mutable-globals runtime
  environment. Macro bindings live in a separate expansion-time
  syntax env threaded through expansion only.

  ## Choosing an entry point

  Schooner's entry points come in pairs following the Elixir
  convention: a tagged-tuple form (`run/1`, `eval/2,3`) and a bang
  form (`run!/1`, `eval!/2,3`) that raises on failure. Choosing
  between `run*` and `eval*` is a **trust decision**, and the names
  can mislead: `eval*` is the sandbox-safe family, `run*` the
  permissive one.

  | Family        | Auto-imports                                                                              | Trust posture                                       | Use for                                                            |
  | ---           | ---                                                                                       | ---                                                 | --- |
  | `run/1`/`run!/1`     | injects `(import ...)` of every shipped standard library when the script declares none | **Not sandbox-safe.** Every shipped primitive is in scope by default. | tests, REPL-style use, your own scripts where you control the source |
  | `eval/2,3`/`eval!/2,3` | none — bindings come exclusively from the `env` argument and the script's own `(import ...)` declarations | **Sandbox-safe.** The embedder controls the surface. | embedding untrusted or semi-trusted scripts |

  `run`/`run!` evaluate against a fresh `Schooner.Env` with the
  `implicit_imports: :all` option of `eval/3` and `eval!/3`. To get
  the same implicit imports against your own `Schooner.Env`, call
  `eval/3` or `eval!/3` with that option directly.

  Within each family, the bang form raises one of:

    * `Schooner.Error` — uncaught Scheme `(raise ...)` in the script
    * `Schooner.Eval.Error` — runtime evaluation failure
    * `Schooner.Primitive.Error` — primitive type / arity / domain error
    * `Schooner.Library.NotFoundError` — `(import ...)` of a missing library
    * `Schooner.Lexer.Error`, `Schooner.Reader.Error`,
      `Schooner.Expander.Error` — source-level failures

  The non-bang form returns `{:ok, value}` on success or
  `{:error, exception}` for any of the above. `ArgumentError`
  raised by malformed options is **not** caught — that is an
  embedder bug, not a script-level failure.

  ### Embedding untrusted code

  Use `eval/2` (or `eval!/2`) and require the script to declare
  exactly which libraries it needs. A script that omits
  `(import ...)` cannot reach any primitive — even `+` is unbound:

      iex> Schooner.eval!("(import (only (scheme base) +)) (+ 1 2)", Schooner.Env.new())
      3

  Pair this with BEAM-level resource limits — run `eval!/2` inside
  a spawned process with `:max_heap_size` and a `Task.shutdown/2`
  timeout so a runaway script cannot exhaust the host. Build the env
  inside that process: an env can only be used by the process that
  created it. See the Running Untrusted Scheme guide.

  For richer sandbox composition (registering host libraries,
  pre-imports, etc.), construct a `Schooner.Environment` via
  `Schooner.Environment.new/1` and pass it to `eval/2`.

  ## Source locations

  Script-level exceptions carry a `:location` field: a
  `Schooner.Location` with the `file`, `line` and `column` of the form
  that failed, or `nil`. Locations are recorded when you ask for them
  by passing `file:` (or `locations: true`) to `eval/3` or
  `compile/3`; the message is then prefixed with `file:line:col: `.
  `format_error/2` renders an error with a source excerpt.

  Tracking positions makes reading and expanding a script about 15%
  slower; it costs nothing while the script runs. Without `file:` or
  `locations: true`, scripts are read without positions and errors
  have `location: nil`.

  With locations on, these errors are always located:

    * lexer and reader errors;
    * malformed special forms and other syntax and expansion errors;
    * an `(import ...)` of a missing library;
    * unbound variables, and `letrec` bindings used before they are
      initialised.

  Errors raised while applying a procedure are located only with
  `debug: true`: primitive type and domain errors, arity mismatches,
  applying a non-procedure, an uncaught `raise` or `(error ...)`, and
  `Schooner.Host.TypeError`s raised by host functions. Debug mode
  wraps each primitive call in a `try` and records every call for a
  backtrace (see "Backtraces" below), which together make call-heavy
  scripts two to three times slower. Without it these errors have
  `location: nil`.

  An error inside a macro expansion is placed in the user's source:
  forms the macro introduces take the position of the macro use, and
  the user's own sub-forms keep theirs. An error in a procedure
  defined by a library loaded from a file is placed in that file (see
  `Schooner.Library.Loader`).

  ## Backtraces

  Proper tail calls leave no Scheme call stack behind, so with
  `debug: true` the evaluator keeps a history of the last
  `:backtrace_depth` procedure calls (32 by default) and attaches it to
  any error that escapes, as `:scheme_backtrace`: a list of
  `Schooner.Frame`s, most recent first. Calls that have returned are
  dropped from it, so it lists the calls that were still running, each
  followed by the tail calls it made. Being bounded, the history never
  grows however long a loop runs. `format_error/2` renders it below
  the excerpt.

  Debug mode is chosen when the program is compiled to closures, so
  without it the closures contain no history code at all and
  `:scheme_backtrace` is `nil`. With it, every call is recorded; that
  is most of debug mode's cost.
  """

  alias Schooner.Compiled
  alias Schooner.Env
  alias Schooner.Environment
  alias Schooner.Eval
  alias Schooner.Eval.Analyze
  alias Schooner.Eval.BacktraceState
  alias Schooner.Eval.ContinuationState
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Eval.ExceptionState
  alias Schooner.Eval.ParameterState
  alias Schooner.Expander
  alias Schooner.Expander.Positions
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Expander.SyntaxRules
  alias Schooner.Frame
  alias Schooner.Lexer
  alias Schooner.Library
  alias Schooner.Library.Import, as: LibImport
  alias Schooner.Location
  alias Schooner.Reader
  alias Schooner.Value

  # Exception types caught by the tagged-tuple wrappers and surfaced
  # as `{:error, exception}`. Anything else propagates — those are
  # embedder bugs (e.g. ArgumentError on malformed options) and
  # should not be silently swallowed.
  @script_exceptions [
    Schooner.Error,
    Schooner.Eval.Error,
    Schooner.Primitive.Error,
    Schooner.Library.NotFoundError,
    Schooner.Lexer.Error,
    Schooner.Reader.Error,
    Schooner.Expander.Error
  ]

  # Implicit imports applied when `implicit_imports: :all` is set and
  # the script has no explicit `(import ...)` of its own. Pre-parsed at
  # compile time so the option path does not pay reader cost on every
  # call.
  @default_implicit_imports_forms Enum.map(
                                    Reader.read_string(
                                      "(import (scheme base) (scheme cxr) (scheme char) " <>
                                        "(scheme inexact) (scheme complex) (scheme write) " <>
                                        "(scheme read) (scheme case-lambda) (scheme lazy))"
                                    ),
                                    &{&1, nil}
                                  )

  @doc """
  Read and evaluate `source` in a fresh empty env, with every shipped
  standard library implicitly imported when the script declares no
  imports of its own.

  Returns `{:ok, value}` on success, `{:error, exception}` for
  any script-level failure. Use `run!/1` for the raising variant.

  **Not for untrusted input.** A script with no `(import ...)`
  form reaches every primitive Schooner ships with. Use `eval/2`
  for embedding scripts you do not control — see "Choosing an
  entry point" in the moduledoc.
  """
  @spec run(binary()) :: {:ok, Value.t()} | {:error, Exception.t()}
  def run(source) when is_binary(source) do
    {:ok, run!(source)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Bang form of `run/1` — raises on script-level failure.
  """
  @spec run!(binary()) :: Value.t()
  def run!(source) when is_binary(source) do
    eval!(source, Env.new(), implicit_imports: :all)
  end

  @doc """
  Read and evaluate `source` against `env`, threading top-level
  definitions and any explicit `(import ...)` bindings into it.

  Returns `{:ok, value}` on success, `{:error, exception}` for
  any script-level failure. Use `eval!/2` for the raising variant.

  `env` may be either a `Schooner.Env` (low-level) or a
  `Schooner.Environment` (the embedding-friendly bundle of env +
  registry + syntax env produced by `Schooner.Environment.new/1`).
  When given an `Env`, no implicit imports are added — bindings
  come exclusively from `env` and the script's own `(import ...)`
  declarations.

  This is the strict path and the right entry point for scripts
  whose source the host does not control. See
  "Choosing an entry point" in the moduledoc.
  """
  @spec eval(binary(), Env.t() | Environment.t()) ::
          {:ok, Value.t()} | {:error, Exception.t()}
  def eval(source, env_or_environment) do
    {:ok, eval!(source, env_or_environment)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Read and evaluate `source` against `env` with `opts`. Returns
  `{:ok, value}` on success, `{:error, exception}` for any
  script-level failure. Use `eval!/3` for the raising variant.

  `env` may be a `Schooner.Env` or a `Schooner.Environment`. Options
  match `eval!/3`.
  """
  @spec eval(binary(), Env.t() | Environment.t(), keyword()) ::
          {:ok, Value.t()} | {:error, Exception.t()}
  def eval(source, env_or_environment, opts) when is_binary(source) and is_list(opts) do
    {:ok, eval!(source, env_or_environment, opts)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Bang form of `eval/2` — raises on script-level failure.
  """
  @spec eval!(binary(), Env.t() | Environment.t()) :: Value.t()
  def eval!(source, env_or_environment) when is_binary(source) do
    eval!(source, env_or_environment, [])
  end

  @doc """
  Bang form of `eval/3` — raises on script-level failure.

  Options:

    * `:file` — the name of the script, recorded in the `:location`
      of any error and prefixed to its message. Passing it turns on
      `:locations`. Defaults to `nil`.
    * `:locations` — when `true`, record the source location of
      errors (see "Source locations" in the moduledoc). Defaults to
      `true` when `:file` or `:debug` is given and `false` otherwise.
    * `:debug` — when `true`, also locate errors raised while applying
      a procedure, at a cost on every primitive call, and attach a
      Scheme backtrace to errors (see "Backtraces" in the moduledoc).
      Implies `locations: true`. Defaults to `false`.
    * `:backtrace_depth` — with `debug: true`, the number of procedure
      calls the backtrace history keeps. A positive integer; defaults
      to 32.
    * `:implicit_imports` — controls implicit imports prepended
      to a script that declares none of its own. Only accepted with a
      `Schooner.Env`; a `Schooner.Environment` bakes its imports in at
      construction time.
        * `:none` (default) — no implicit imports. Bindings come
          exclusively from `env` and the script's own
          `(import ...)` declarations. Use this for untrusted
          input.
        * `:all` — implicitly import every shipped standard
          library. Skipped if the script declares any
          `(import ...)` of its own: an explicit import means
          the script has chosen a narrower surface.
  """
  @spec eval!(binary(), Env.t() | Environment.t(), keyword()) :: Value.t()
  def eval!(source, %Env{} = env, opts) when is_binary(source) and is_list(opts) do
    forms = read(source, opts)
    forms = apply_implicit_imports(forms, opts)
    do_eval(forms, env, Expander.bootstrap_env(), Library.standard(), opts)
  end

  def eval!(source, %Environment{} = environment, opts)
      when is_binary(source) and is_list(opts) do
    if Keyword.has_key?(opts, :implicit_imports) do
      raise ArgumentError,
            ":implicit_imports is not supported with a Schooner.Environment, " <>
              "which fixes its imports when it is built"
    end

    %Environment{env: env, syntax_env: syntax_env, registry: registry} = environment
    do_eval(read(source, opts), env, syntax_env, registry, opts)
  end

  # Positions are only read, and carried through expansion and
  # analysis, when the caller asks for locations: that work slows the
  # front end, so a caller who does not want locations does not pay
  # for it.
  defp read(source, opts) do
    if locations?(opts) do
      in_file(opts, fn -> Reader.read_string_positioned(source) end)
    else
      try do
        source |> Reader.read_string() |> Enum.map(&{&1, nil})
      rescue
        # Lexer and reader errors carry their position anyway; with
        # locations off they have no location, like every other error.
        e in [Lexer.Error, Reader.Error] -> reraise %{e | location: nil}, __STACKTRACE__
      end
    end
  end

  defp locations?(opts) do
    Keyword.get_lazy(opts, :locations, fn ->
      Keyword.get(opts, :file) != nil or Keyword.get(opts, :debug, false)
    end)
  end

  # Name the script's file in the location of an error raised by `fun`
  # before the file was known: by the reader, import resolution or the
  # expander.
  defp in_file(opts, fun) do
    fun.()
  rescue
    e -> reraise Location.put_file(e, Keyword.get(opts, :file)), __STACKTRACE__
  end

  defp apply_implicit_imports(forms, opts) do
    case Keyword.get(opts, :implicit_imports, :none) do
      :none ->
        forms

      :all ->
        {explicit_imports, _body} = extract_imports(forms)

        case explicit_imports do
          [] -> @default_implicit_imports_forms ++ forms
          _ -> forms
        end

      other ->
        raise ArgumentError,
              "invalid value for :implicit_imports — expected :none or :all, got: " <>
                inspect(other)
    end
  end

  # The leading `(import ...)` forms of a positioned program, as a list
  # of `{spec, tree}` pairs, and the rest of the program.
  defp extract_imports(forms), do: extract_imports(forms, [])

  defp extract_imports([{[{:sym, "import"} | specs], tree} | rest], acc) do
    pairs =
      specs
      |> Value.to_list()
      |> Enum.with_index(1)
      |> Enum.map(fn {spec, i} -> {spec, Positions.nth(tree, i)} end)

    extract_imports(rest, [pairs | acc])
  end

  defp extract_imports(rest, acc), do: {acc |> Enum.reverse() |> Enum.concat(), rest}

  # Resolve import specs one at a time, so that a failure is placed at
  # the spec that caused it. Later specs shadow earlier ones, as in
  # `Schooner.Library.Import.resolve/2`.
  defp resolve_imports(spec_pairs, registry) do
    Enum.reduce(spec_pairs, %{}, fn {spec, tree}, acc ->
      Map.merge(acc, resolve_import(spec, tree, registry))
    end)
  end

  defp resolve_import(spec, tree, registry) do
    LibImport.resolve([spec], registry)
  rescue
    e -> reraise Location.attach(e, Location.new(nil, Positions.at(tree))), __STACKTRACE__
  end

  # The front end shared by `eval!/3` and `compile!/3`:
  # resolve the program's imports against `registry` and expand its
  # body.
  defp front_end(forms, env, syntax_env, registry, opts) do
    in_file(opts, fn ->
      {import_specs, body} = extract_imports(forms)
      bindings = resolve_imports(import_specs, registry)
      {env, syntax_env} = LibImport.apply_bindings(bindings, env, syntax_env)
      {expanded, _syntax_env} = Expander.expand_positioned(body, syntax_env)
      {bindings, env, expanded}
    end)
  end

  defp eval_opts(opts), do: Keyword.take(opts, [:file, :debug, :backtrace_depth])

  # The size of the backtrace history to keep, or `nil` without `debug`.
  defp backtrace_depth(opts) do
    if Keyword.get(opts, :debug, false) do
      case Keyword.get(opts, :backtrace_depth, BacktraceState.default_depth()) do
        depth when is_integer(depth) and depth > 0 ->
          depth

        other ->
          raise ArgumentError,
                "invalid value for :backtrace_depth — expected a positive integer, got: " <>
                  inspect(other)
      end
    end
  end

  @doc """
  Invoke a Scheme procedure value from Elixir. Returns
  `{:ok, value}` on success, `{:error, exception}` for any
  script-level failure. Use `apply!/2` for the raising variant.

  `proc` may be any procedure value — a closure (returned by
  evaluating a `lambda` or a `define` form), a primitive, or a
  parameter. `args` is a list of `t:Schooner.Value.t/0` arguments.

  This is the host-side hook for callback patterns: pass a Scheme
  procedure into a host function, capture it, and invoke it later
  via `apply/2`.
  """
  @spec apply(Value.t(), [Value.t()]) :: {:ok, Value.t()} | {:error, Exception.t()}
  def apply(proc, args) when is_list(args) do
    {:ok, apply!(proc, args)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Bang form of `apply/2` — raises on script-level failure. See
  `apply/2` for arguments.
  """
  @spec apply!(Value.t(), [Value.t()]) :: Value.t()
  def apply!(proc, args) when is_list(args) do
    if Value.procedure?(proc) do
      proc |> Eval.apply_proc(args) |> Eval.single_value!()
    else
      raise EvalError, reason: {:not_a_procedure, proc}
    end
  end

  @doc """
  Read, expand, and pre-resolve `source` against `env_struct`'s
  registry. Returns `{:ok, %Schooner.Compiled{}}` on success,
  `{:error, exception}` on any source-level failure. Use
  `compile!/1,2` for the raising variant.

  The compiled artifact can be passed to `run_compiled/3`
  repeatedly against any compatible environment. Macros are
  expanded at compile time; variable bindings from `(import ...)`
  declarations are pre-resolved and baked into the artifact.

  Options are `:file`, `:locations`, `:debug` and `:backtrace_depth`,
  as for `eval!/3`. They are kept in the artifact, so `run_compiled/3`
  reports the same locations.
  """
  @spec compile(binary(), Environment.t(), keyword()) ::
          {:ok, Compiled.t()} | {:error, Exception.t()}
  def compile(source, env_struct, opts \\ []) when is_binary(source) and is_list(opts) do
    {:ok, compile!(source, env_struct, opts)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Compile `source` against a fresh `Schooner.Environment.new/0`, in
  which every shipped standard library is available to import. See
  `compile/2`.
  """
  @spec compile(binary()) :: {:ok, Compiled.t()} | {:error, Exception.t()}
  def compile(source) when is_binary(source) do
    compile(source, Environment.new())
  end

  @doc """
  Bang form of `compile/3` — raises on source-level failure.
  """
  @spec compile!(binary(), Environment.t(), keyword()) :: Compiled.t()
  def compile!(source, env_struct, opts \\ []) when is_binary(source) and is_list(opts) do
    {bindings, _compile_env, expanded} =
      source
      |> read(opts)
      |> front_end(
        Environment.env(env_struct),
        Environment.syntax_env(env_struct),
        Environment.registry(env_struct),
        opts
      )

    var_bindings =
      Enum.reduce(bindings, %{}, fn
        {name, {:var, _} = binding}, acc -> Map.put(acc, name, binding)
        _, acc -> acc
      end)

    program = Enum.map(expanded, fn {form, tree} -> Analyze.analyze(form, tree) end)
    Compiled.new(program, var_bindings, eval_opts(opts))
  end

  @doc """
  Bang form of `compile/1` — raises on source-level failure.
  """
  @spec compile!(binary()) :: Compiled.t()
  def compile!(source) when is_binary(source) do
    compile!(source, Environment.new())
  end

  @doc """
  Evaluate a `%Schooner.Compiled{}` against `env_struct`. Returns
  `{:ok, value}` on success, `{:error, exception}` for any
  script-level failure. Use `run_compiled!/3` for the raising
  variant.

  The compiled program's pre-resolved variable bindings are
  re-applied to `env_struct.env` on every call, so the
  `(import ...)` surface the program was compiled against is
  always in scope regardless of `env_struct`'s registry. Macros
  are not re-expanded — the program's macro shape is frozen at
  compile time.

  Options override those the program was compiled with:

    * `:debug` — as for `eval!/3`. The program is compiled to closures
      on each run, so one artifact can run with or without it. Errors
      are located only if the program was compiled with locations.
    * `:backtrace_depth` — as for `eval!/3`.
  """
  @spec run_compiled(Compiled.t(), Environment.t(), keyword()) ::
          {:ok, Value.t()} | {:error, Exception.t()}
  def run_compiled(compiled, env_struct, opts \\ []) when is_list(opts) do
    {:ok, run_compiled!(compiled, env_struct, opts)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Bang form of `run_compiled/3` — raises on script-level failure.
  """
  @spec run_compiled!(Compiled.t(), Environment.t(), keyword()) :: Value.t()
  def run_compiled!(compiled, env_struct, opts \\ []) when is_list(opts) do
    opts = Keyword.validate!(opts, [:debug, :backtrace_depth])

    do_run_program(
      Compiled.program(compiled),
      Compiled.var_bindings(compiled),
      Environment.env(env_struct),
      Environment.syntax_env(env_struct),
      Keyword.merge(Compiled.opts(compiled), opts)
    )
  end

  defp do_run_program(program, var_bindings, env, syntax_env, opts) do
    depth = backtrace_depth(opts)
    prev_handlers = ExceptionState.snapshot()
    prev_conts = ContinuationState.snapshot()
    prev_params = ParameterState.snapshot()
    prev_history = BacktraceState.snapshot()
    ExceptionState.reset()
    ContinuationState.reset()
    ParameterState.reset()
    BacktraceState.reset(depth)

    try do
      {env, _syntax_env} = LibImport.apply_bindings(var_bindings, env, syntax_env)

      program
      |> Enum.reduce(:unspecified, fn node, _acc -> Eval.exec(node, env, opts) end)
      |> Eval.single_value!()
    rescue
      e -> reraise BacktraceState.attach(e), __STACKTRACE__
    after
      ExceptionState.restore(prev_handlers)
      ContinuationState.restore(prev_conts)
      ParameterState.restore(prev_params)
      BacktraceState.restore(prev_history)
    end
  end

  defp do_eval(forms, %Env{} = env, syntax_env, registry, opts) do
    # Snapshot/restore the per-process control state so each top-level
    # call starts clean. Without this, a script that pushes a handler
    # or registers a `call/cc` tag then escapes via a host-side throw
    # (e.g. a test that catches `Schooner.Error`) would leak state into
    # the next call in the same process.
    depth = backtrace_depth(opts)
    prev_handlers = ExceptionState.snapshot()
    prev_conts = ContinuationState.snapshot()
    prev_params = ParameterState.snapshot()
    prev_history = BacktraceState.snapshot()
    ExceptionState.reset()
    ContinuationState.reset()
    ParameterState.reset()
    BacktraceState.reset(depth)

    try do
      {_bindings, env, expanded} = front_end(forms, env, syntax_env, registry, opts)
      eval_opts = eval_opts(opts)

      expanded
      |> Enum.reduce(:unspecified, fn {form, tree}, _acc ->
        Eval.eval(form, tree, env, eval_opts)
      end)
      |> Eval.single_value!()
    rescue
      # With `debug: true`, give a runtime error the calls that led to
      # it. Nothing between the raise and here records a call (see
      # `Schooner.Eval.BacktraceState`), so the history is the raise's.
      e -> reraise BacktraceState.attach(e), __STACKTRACE__
    after
      ExceptionState.restore(prev_handlers)
      ContinuationState.restore(prev_conts)
      ParameterState.restore(prev_params)
      BacktraceState.restore(prev_history)
    end
  end

  @doc ~S"""
  Check `source` against `environment` without running it, and return
  the problems found as a list of `Schooner.Diagnostic`s. An empty
  list means nothing was found.

  The script is read, its imports are resolved against
  `environment`'s registry, and its macros are expanded, just as
  `eval/3` would, but **no part of it is evaluated** and
  `environment` is left unchanged. That makes `check/3` safe to call
  on untrusted scripts, for example when one is saved. Expansion
  still runs the script's own `syntax-rules` macros, and a macro that
  expands forever never returns, so bound the call with a timeout as
  you would `eval/3`.

  The checker reports:

    * `:read_error` — the source doesn't parse. Nothing else is
      checked.
    * `:syntax_error` — a malformed special form, macro use or
      `import` set.
    * `:unknown_library` — an `(import ...)` of a library the
      environment's registry doesn't have.
    * `:unbound` — a reference to a name that isn't bound by the
      environment, an import or a definition anywhere in the script.
    * `:arity` — a call, with a fixed number of arguments, to a
      procedure that can't accept that many: a primitive or procedure
      the environment or an import binds, or one the script defines
      once with `lambda` (or `(define (name ...) ...)`) and nothing
      else binds.

  Every form is checked, including branches that would never run, so
  a reference to an unbound name in dead code is still reported.
  When an import fails, the names it would have bound are unknown, so
  `:unbound` is not reported for that script.

      iex> environment = Schooner.Environment.new(pre_imports: [["scheme", "base"]])
      iex> Schooner.check("(define (f x) (+ x y))\n(f 1 2)", environment, file: "f.scm")
      [
        %Schooner.Diagnostic{
          severity: :error,
          code: :unbound,
          message: "unbound variable: y",
          location: %Schooner.Location{file: "f.scm", line: 1, column: 20}
        },
        %Schooner.Diagnostic{
          severity: :error,
          code: :arity,
          message: "arity mismatch in `f`: expected 1, got 2",
          location: %Schooner.Location{file: "f.scm", line: 2, column: 1}
        }
      ]

  Diagnostics are ordered by location. Every diagnostic reported today
  is an `:error`: something that fails the script if evaluation
  reaches it.

  Options:

    * `:file` — the name of the script, recorded in the location of
      every diagnostic. Defaults to `nil`.
  """
  @spec check(binary(), Environment.t(), keyword()) :: [Schooner.Diagnostic.t()]
  def check(source, %Environment{} = environment, opts \\ [])
      when is_binary(source) and is_list(opts) do
    opts = Keyword.validate!(opts, file: nil)
    Schooner.Checker.check(source, environment, opts)
  end

  @typedoc """
  One macro use expanded by `expand/3` with `trace: true`: the macro's
  name, the location of the use (`nil` when unknown), the use itself,
  and what the macro rewrote it to.
  """
  @type expansion_step :: %{
          macro: binary(),
          location: Location.t() | nil,
          before: Value.t(),
          after: Value.t()
        }

  @doc ~S"""
  Expand the macros in `source` against `environment` without running
  it, and return the expanded top-level forms.

  The script is read, its imports are resolved against
  `environment`'s registry, and its macros are expanded, as `eval/3`
  would, but **no part of it is evaluated** and `environment` is left
  unchanged. Many standard forms (`cond`, `case`, the `let` family,
  `do`, `and`, `or`, `when`, `unless`) are `syntax-rules` macros, so
  this shows what they, and the script's own macros, turn into.
  Render the forms with `Schooner.Pretty.format/2`:

      iex> environment = Schooner.Environment.new(pre_imports: [["scheme", "base"]])
      iex> {:ok, [form]} = Schooner.expand("(when (> n 0) (go n))", environment)
      iex> Schooner.Pretty.format(form)
      "(if (> n 0) (begin (go n)))"

  The `(import ...)` forms are not returned, and nor are the
  `define-syntax` forms, whose macros are expanded where the script
  uses them. Expansion runs the script's `syntax-rules` macros, and a
  macro that expands forever never returns, so bound the call with a
  timeout as you would `eval/3`.

  An identifier a macro introduces is renamed for hygiene, so that it
  can't capture or be captured by the script's own identifiers.
  `Schooner.Pretty` prints a renamed identifier with a number, such as
  `tmp·1`. Numbers are assigned from 1 in the order the identifiers
  appear in the result, so the output is the same on every run:

      iex> environment = Schooner.Environment.new(pre_imports: [["scheme", "base"]])
      iex> {:ok, [form]} = Schooner.expand("(or (f) tmp)", environment)
      iex> Schooner.Pretty.format(form)
      "((lambda (t·1) (if t·1 t·1 tmp)) (f))"

  Returns `{:ok, forms}`, `{:ok, forms, steps}` with `trace: true`, or
  `{:error, exception}` when the script can't be read, imports a
  library the registry doesn't have, or uses a macro or special form
  wrongly. Errors are located as with `eval/3` and `locations: true`.

  Options:

    * `:file` — the name of the script, recorded in locations and
      error messages. Defaults to `nil`.
    * `:step` — `:full` (the default) expands until only core forms
      are left. `:once` expands each macro use that is not inside
      another macro use once, and leaves the macro uses in its output
      as they are:

          iex> environment = Schooner.Environment.new(pre_imports: [["scheme", "base"]])
          iex> {:ok, [form]} = Schooner.expand("(cond (a 1) (b 2))", environment, step: :once)
          iex> Schooner.Pretty.format(form)
          "(if a (begin 1) (cond·1 (b 2)))"

    * `:trace` — when `true`, also return every macro use expanded, in
      the order it was expanded, as a list of `t:expansion_step/0`
      maps:

          iex> environment = Schooner.Environment.new(pre_imports: [["scheme", "base"]])
          iex> {:ok, _forms, [step]} = Schooner.expand("(unless ok (fail))", environment, trace: true)
          iex> {step.macro, step.location}
          {"unless", %Schooner.Location{file: nil, line: 1, column: 1}}
          iex> Schooner.Pretty.format(step.after)
          "(if ok (begin) (begin (fail)))"

      Defaults to `false`.
  """
  @spec expand(binary(), Environment.t(), keyword()) ::
          {:ok, [Value.t()]} | {:ok, [Value.t()], [expansion_step()]} | {:error, Exception.t()}
  def expand(source, %Environment{} = environment, opts \\ [])
      when is_binary(source) and is_list(opts) do
    opts = Keyword.validate!(opts, file: nil, step: :full, trace: false)
    step = Keyword.fetch!(opts, :step)
    trace? = Keyword.fetch!(opts, :trace)

    unless step in [:full, :once] do
      raise ArgumentError,
            "invalid value for :step, expected :full or :once, got: #{inspect(step)}"
    end

    unless is_boolean(trace?) do
      raise ArgumentError, "invalid value for :trace, expected a boolean, got: #{inspect(trace?)}"
    end

    {expanded, steps} = expand_front_end(source, environment, step, trace?, opts)
    file = Keyword.fetch!(opts, :file)

    # Renumber the forms first, so that they print the same with or
    # without a trace.
    {forms, step_forms} =
      expanded
      |> Enum.map(&elem(&1, 0))
      |> Kernel.++(Enum.flat_map(steps, fn {_, before, _, after_} -> [before, after_] end))
      |> SyntaxRules.renumber_marks()
      |> Enum.split(length(expanded))

    if trace? do
      steps =
        steps
        |> Enum.zip(Enum.chunk_every(step_forms, 2))
        |> Enum.map(fn {{macro, _, tree, _}, [before, after_]} ->
          %{
            macro: macro,
            location: Location.new(file, Positions.at(tree)),
            before: before,
            after: after_
          }
        end)

      {:ok, forms, steps}
    else
      {:ok, forms}
    end
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  # Read `source` with positions, resolve its imports and expand it,
  # without touching `environment`: only the imported macros are
  # needed, and they go into a copy of its syntax env.
  defp expand_front_end(source, %Environment{} = environment, step, trace?, opts) do
    %Environment{syntax_env: syntax_env, registry: registry} = environment

    in_file(opts, fn ->
      forms = Reader.read_string_positioned(source)
      {import_specs, body} = forms |> check_import_forms!() |> extract_imports()

      syntax_env =
        import_specs
        |> Enum.reduce(%{}, fn {spec, tree}, acc ->
          Map.merge(acc, resolve_checked_import!(spec, tree, registry))
        end)
        |> Enum.reduce(syntax_env, fn
          {name, {:macro, transformer}}, se -> SyntaxEnv.define_macro(se, name, transformer)
          _, se -> se
        end)

      Expander.inspect_positioned(body, syntax_env, step, trace?)
    end)
  end

  # `eval/3` lets the `ArgumentError` from a malformed import set
  # escape. `expand/3` reports it as a malformed `import`, as
  # `check/3` does, placed at the form or the spec.
  defp check_import_forms!([{[{:sym, "import"} | specs], tree} | rest] = forms) do
    unless Value.list?(specs), do: raise_bad_import(tree)
    check_import_forms!(rest)
    forms
  end

  defp check_import_forms!(forms), do: forms

  defp resolve_checked_import!(spec, tree, registry) do
    resolve_import(spec, tree, registry)
  rescue
    ArgumentError -> raise_bad_import(tree)
  end

  defp raise_bad_import(tree) do
    error = EvalError.exception(reason: {:bad_special_form, "import"})
    raise Location.attach(error, Location.new(nil, Positions.at(tree)))
  end

  @doc ~S"""
  Render a script-level exception for people.

  The first line is the message, prefixed with the error's location
  (`file:line:col: ` or `line:col: `) when it has one. With
  `source: binary` — the text of the script the location points into —
  a short excerpt follows, with a caret under the failing column:

      iex> source = "(define x 1)\n(car y)"
      iex> {:error, e} =
      ...>   Schooner.eval(source, Schooner.Env.new(), implicit_imports: :all, file: "demo.scm")
      iex> Schooner.format_error(e, source: source)
      "demo.scm:2:6: unbound variable: y\n  |\n2 | (car y)\n  |      ^"

  An error raised with `debug: true` also has a Scheme backtrace (see
  "Backtraces" in the moduledoc), which is listed last, one call per
  line, most recent first. A call in tail position is marked
  `(tail call)`:

      iex> source = "(define (f x) (car x))\n(define (g x) (+ 1 (f x)))\n(g 1)"
      iex> {:error, e} =
      ...>   Schooner.eval(source, Schooner.Env.new(),
      ...>     implicit_imports: :all, file: "demo.scm", debug: true)
      iex> Schooner.format_error(e) |> String.split("\n")
      [
        "demo.scm:1:15: type error in `car`: expected pair, got 1",
        "",
        "Scheme backtrace (most recent first):",
        "  car  demo.scm:1:15 (tail call)",
        "  f    demo.scm:2:20",
        "  g    demo.scm:3:1"
      ]

  Options:

    * `:source` — the script's source text. Without it, or when the
      error has no location, only the message is returned.
  """
  @spec format_error(Exception.t(), keyword()) :: binary()
  def format_error(exception, opts \\ []) when is_exception(exception) and is_list(opts) do
    message = Exception.message(exception)

    located =
      case Map.get(exception, :location) do
        %Location{file: nil} = loc ->
          "#{loc}: #{message}" <> excerpt(loc, Keyword.get(opts, :source))

        %Location{} = loc ->
          message <> excerpt(loc, Keyword.get(opts, :source))

        _ ->
          message
      end

    located <> backtrace(Map.get(exception, :scheme_backtrace))
  end

  defp backtrace([_ | _] = frames) do
    width = frames |> Enum.map(&String.length(&1.name)) |> Enum.max()

    lines =
      Enum.map(frames, fn %Frame{name: name, location: loc, tail?: tail?} ->
        where = if loc, do: to_string(loc), else: "(unknown location)"

        [
          "\n  ",
          String.pad_trailing(name, width + 2),
          where,
          if(tail?, do: " (tail call)", else: "")
        ]
      end)

    IO.iodata_to_binary(["\n\nScheme backtrace (most recent first):" | lines])
  end

  defp backtrace(_frames), do: ""

  defp excerpt(_loc, nil), do: ""

  defp excerpt(%Location{line: line, column: column}, source) when is_binary(source) do
    # Split lines as the lexer counts them.
    case source |> String.split(~r/\r\n|\r|\n/) |> Enum.at(line - 1) do
      nil ->
        ""

      text ->
        number = Integer.to_string(line)
        gutter = String.duplicate(" ", String.length(number)) <> " |"
        # The column counts codepoints, as the lexer does. Pad one
        # space per grapheme before it, keeping tabs so the caret lines
        # up under them.
        pad =
          text
          |> String.codepoints()
          |> Enum.take(column - 1)
          |> Enum.join()
          |> String.graphemes()
          |> Enum.map_join(fn
            "\t" -> "\t"
            _ -> " "
          end)

        "\n" <> gutter <> "\n" <> number <> " | " <> text <> "\n" <> gutter <> " " <> pad <> "^"
    end
  end

  defp rescue_script_error(e, stacktrace) do
    if e.__struct__ in @script_exceptions do
      {:error, e}
    else
      reraise e, stacktrace
    end
  end
end
