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
  wraps each primitive call in a `try`, which makes scripts that spend
  their time in primitives (list, string and vector work) 10–15%
  slower; arithmetic on integers is unaffected. Without it these
  errors have `location: nil`.

  An error inside a macro expansion is placed in the user's source:
  forms the macro introduces take the position of the macro use, and
  the user's own sub-forms keep theirs. An error in a procedure
  defined by a library loaded from a file is placed in that file (see
  `Schooner.Library.Loader`).
  """

  alias Schooner.Compiled
  alias Schooner.Env
  alias Schooner.Environment
  alias Schooner.Eval
  alias Schooner.Eval.Analyze
  alias Schooner.Eval.ContinuationState
  alias Schooner.Eval.Error, as: EvalError
  alias Schooner.Eval.ExceptionState
  alias Schooner.Eval.ParameterState
  alias Schooner.Expander
  alias Schooner.Expander.Positions
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
      a procedure, at a cost on every primitive call. Implies
      `locations: true`. Defaults to `false`.
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

  defp eval_opts(opts), do: Keyword.take(opts, [:file, :debug])

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

  The compiled artifact can be passed to `run_compiled/2`
  repeatedly against any compatible environment. Macros are
  expanded at compile time; variable bindings from `(import ...)`
  declarations are pre-resolved and baked into the artifact.

  Options are `:file`, `:locations` and `:debug`, as for `eval!/3`.
  They are kept in the artifact, so `run_compiled/2` reports the same
  locations.
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
  script-level failure. Use `run_compiled!/2` for the raising
  variant.

  The compiled program's pre-resolved variable bindings are
  re-applied to `env_struct.env` on every call, so the
  `(import ...)` surface the program was compiled against is
  always in scope regardless of `env_struct`'s registry. Macros
  are not re-expanded — the program's macro shape is frozen at
  compile time.
  """
  @spec run_compiled(Compiled.t(), Environment.t()) ::
          {:ok, Value.t()} | {:error, Exception.t()}
  def run_compiled(compiled, env_struct) do
    {:ok, run_compiled!(compiled, env_struct)}
  rescue
    e -> rescue_script_error(e, __STACKTRACE__)
  end

  @doc """
  Bang form of `run_compiled/2` — raises on script-level failure.
  """
  @spec run_compiled!(Compiled.t(), Environment.t()) :: Value.t()
  def run_compiled!(compiled, env_struct) do
    do_run_program(
      Compiled.program(compiled),
      Compiled.var_bindings(compiled),
      Environment.env(env_struct),
      Environment.syntax_env(env_struct),
      Compiled.opts(compiled)
    )
  end

  defp do_run_program(program, var_bindings, env, syntax_env, opts) do
    prev_handlers = ExceptionState.snapshot()
    prev_conts = ContinuationState.snapshot()
    prev_params = ParameterState.snapshot()
    ExceptionState.reset()
    ContinuationState.reset()
    ParameterState.reset()

    try do
      {env, _syntax_env} = LibImport.apply_bindings(var_bindings, env, syntax_env)

      program
      |> Enum.reduce(:unspecified, fn node, _acc -> Eval.exec(node, env, opts) end)
      |> Eval.single_value!()
    after
      ExceptionState.restore(prev_handlers)
      ContinuationState.restore(prev_conts)
      ParameterState.restore(prev_params)
    end
  end

  defp do_eval(forms, %Env{} = env, syntax_env, registry, opts) do
    # Snapshot/restore the per-process control state so each top-level
    # call starts clean. Without this, a script that pushes a handler
    # or registers a `call/cc` tag then escapes via a host-side throw
    # (e.g. a test that catches `Schooner.Error`) would leak state into
    # the next call in the same process.
    prev_handlers = ExceptionState.snapshot()
    prev_conts = ContinuationState.snapshot()
    prev_params = ParameterState.snapshot()
    ExceptionState.reset()
    ContinuationState.reset()
    ParameterState.reset()

    try do
      {_bindings, env, expanded} = front_end(forms, env, syntax_env, registry, opts)
      eval_opts = eval_opts(opts)

      expanded
      |> Enum.reduce(:unspecified, fn {form, tree}, _acc ->
        Eval.eval(form, tree, env, eval_opts)
      end)
      |> Eval.single_value!()
    after
      ExceptionState.restore(prev_handlers)
      ContinuationState.restore(prev_conts)
      ParameterState.restore(prev_params)
    end
  end

  @doc ~S"""
  Render a script-level exception for people.

  The first line is the message, prefixed with the error's location
  (`file:line:col: ` or `line:col: `) when it has one. With
  `source: binary` — the text of the script the location points into —
  a short excerpt follows, with a caret under the failing column:

      iex> source = "(define x 1)\n(car x)"
      iex> {:error, e} =
      ...>   Schooner.eval(source, Schooner.Env.new(),
      ...>     implicit_imports: :all, file: "demo.scm", debug: true)
      iex> Schooner.format_error(e, source: source)
      "demo.scm:2:1: type error in `car`: expected pair, got 1\n  |\n2 | (car x)\n  | ^"

  Options:

    * `:source` — the script's source text. Without it, or when the
      error has no location, only the message is returned.
  """
  @spec format_error(Exception.t(), keyword()) :: binary()
  def format_error(exception, opts \\ []) when is_exception(exception) and is_list(opts) do
    message = Exception.message(exception)

    case Map.get(exception, :location) do
      %Location{file: nil} = loc ->
        "#{loc}: #{message}" <> excerpt(loc, Keyword.get(opts, :source))

      %Location{} = loc ->
        message <> excerpt(loc, Keyword.get(opts, :source))

      _ ->
        message
    end
  end

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
