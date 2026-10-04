defmodule Schooner.REPL do
  @moduledoc false

  # The loop behind `mix schooner.repl`.
  #
  # The session lives in an evaluator process of its own, so the REPL
  # can stop an evaluation that runs away without stopping itself: an
  # environment's definitions live in the dictionary of the process
  # that built it, and a process can't be interrupted, only killed. So
  # the evaluator builds the environment, and after every request sends
  # back a snapshot of its session and dictionary. When an evaluation
  # is interrupted, or the evaluator dies, the REPL starts a new one
  # from the last snapshot: the session as it was before that entry.
  #
  # Restoring copies the snapshot into the new process, and copying a
  # term doesn't keep the sharing between its parts, so after a restore
  # two definitions that held the same pair or vector hold equal ones,
  # which `eq?` tells apart.
  #
  # Input comes one of two ways. With `mode: :editor`, a reader process
  # sends the REPL each character typed and the REPL edits entries with
  # `Schooner.REPL.Editor`, which indents continuation lines as they are
  # typed; Ctrl-C then interrupts an evaluation. With `mode: :line`, the
  # REPL reads whole lines, for input that isn't a terminal.

  alias Schooner.Library
  alias Schooner.Pretty
  alias Schooner.REPL.Editor
  alias Schooner.REPL.Input
  alias Schooner.Session
  alias Schooner.Value

  @help """
  Enter Scheme to evaluate it. An entry that ends inside an open form
  continues on the next line.

  Commands:
    ,env [prefix]   list the bindings in scope, or those starting with prefix
    ,expand <form>  show what <form> expands to
    ,time <form>    evaluate <form> and report its wall time and reductions
    ,load <file>    evaluate a file into the session
    ,help           show this help
    ,quit           leave (or Ctrl-D)
  """

  @editor_help """

  Keys: Tab re-indents the line, Up and Down recall earlier entries,
  and Ctrl-C discards the entry, or interrupts an evaluation.
  """

  @workers {__MODULE__, :workers}

  defstruct [
    :input,
    :output,
    :mode,
    :echo?,
    :evaluator,
    :snapshot,
    :reader,
    :editor,
    :columns,
    pending: ""
  ]

  @doc """
  Run the REPL until the input ends or `,quit`.

  Options:

    * `:environment` (required) — a zero-arity function that returns
      the `Schooner.Environment`. It is called in the evaluator.
    * `:session` — options for `Schooner.Session.new/2`.
    * `:load` — files to evaluate before the first prompt.
    * `:banner` — a line written first.
    * `:input`, `:output` — the devices to read and write. Default
      `:stdio`.
    * `:mode` — `:editor` or `:line` (above). Default `:line`.
    * `:echo` — in line mode, write each line read after its prompt,
      as a terminal would. Default `false`.
    * `:columns` — a function returning the terminal's width.

  Raises when the environment function does.
  """
  @spec run(keyword()) :: :ok
  def run(opts) do
    output = Keyword.get(opts, :output, :stdio)

    state = %__MODULE__{
      input: Keyword.get(opts, :input, :stdio),
      output: output,
      mode: Keyword.get(opts, :mode, :line),
      echo?: Keyword.get(opts, :echo, false),
      columns: Keyword.get(opts, :columns, fn -> 80 end),
      editor: Editor.new()
    }

    previous_workers = Process.put(@workers, [])

    try do
      serve(state, opts)
    after
      stop_workers(previous_workers)
    end

    :ok
  end

  defp serve(state, opts) do
    environment = Keyword.fetch!(opts, :environment)
    session_opts = Keyword.get(opts, :session, [])
    state = start_evaluator(state, {:build, environment, session_opts})
    if banner = opts[:banner], do: write(state, [banner, "\n"])
    state = if state.mode == :editor, do: start_reader(state), else: state

    state =
      Enum.reduce(Keyword.get(opts, :load, []), state, fn file, state ->
        {text, state} = request(state, load_request(file))
        write(state, text)
        state
      end)

    case state.mode do
      :editor -> state |> prompt() |> editor_loop()
      :line -> line_loop(state)
    end
  end

  # ---------------------------------------------------------------------------
  # Line mode
  # ---------------------------------------------------------------------------

  defp line_loop(state) do
    case read_entry(state, Editor.prompt(), "") do
      :eof ->
        state

      {:entry, text} ->
        case entry(state, text) do
          {:quit, state} -> state
          {:continue, state} -> line_loop(state)
        end
    end
  end

  defp read_entry(state, prompt, acc) do
    write(state, prompt)

    case IO.gets(state.input, "") do
      line when is_binary(line) ->
        if state.echo?, do: write(state, line)
        text = acc <> line

        if Input.complete?(text),
          do: {:entry, String.replace_suffix(text, "\n", "")},
          else: read_entry(state, Editor.continuation(), text)

      _eof_or_error ->
        # End the prompt's line. Unfinished source is still evaluated,
        # to report what was left open.
        write(state, "\n")
        if String.trim(acc) == "", do: :eof, else: {:entry, String.replace_suffix(acc, "\n", "")}
    end
  end

  # ---------------------------------------------------------------------------
  # Editor mode
  # ---------------------------------------------------------------------------

  defp start_reader(state) do
    repl = self()
    input = state.input

    reader =
      spawn_link(fn ->
        Stream.repeatedly(fn -> IO.getn(input, "", 1) end)
        |> Enum.each(fn
          data when is_binary(data) ->
            send(repl, {:repl_input, self(), data})

          _eof_or_error ->
            send(repl, {:repl_input, self(), :eof})
            exit(:normal)
        end)
      end)

    track({reader, :link})
    %{state | reader: reader}
  end

  defp prompt(state) do
    {editor, prompt} = Editor.start(state.editor)
    write(state, prompt)
    %{state | editor: editor}
  end

  defp editor_loop(%{reader: reader} = state) do
    receive do
      {:repl_input, ^reader, :eof} ->
        write(state, "\n")
        state

      {:repl_input, ^reader, data} ->
        {keys, pending} = Editor.feed(state.pending, data)

        case keys(%{state | pending: pending}, keys) do
          {:quit, state} -> state
          {:continue, state} -> editor_loop(state)
        end
    end
  end

  defp keys(state, []), do: {:continue, state}

  defp keys(state, [key | rest]) do
    {action, editor, output} = Editor.key(state.editor, key, state.columns.())
    write(state, output)
    state = %{state | editor: editor}

    case action do
      :continue ->
        keys(state, rest)

      :eof ->
        {:quit, state}

      {:submit, text} ->
        case entry(state, text) do
          {:quit, state} -> {:quit, state}
          {:continue, state} -> state |> prompt() |> keys(rest)
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Entries
  # ---------------------------------------------------------------------------

  defp entry(state, text) do
    case Input.command(text) do
      nil ->
        if String.trim(text) == "",
          do: {:continue, state},
          else: respond(state, eval_request(text))

      {"quit", _} ->
        {:quit, state}

      {"help", _} ->
        write(state, if(state.mode == :editor, do: [@help, @editor_help], else: @help))
        {:continue, state}

      {name, args} ->
        case command_request(name, String.trim(args)) do
          {:ok, request} ->
            respond(state, request)

          {:error, message} ->
            write(state, ["error: ", message, "\n"])
            {:continue, state}
        end
    end
  end

  defp respond(state, request) do
    {text, state} = request(state, request)
    write(state, text)
    {:continue, state}
  end

  defp command_request("env", prefix), do: {:ok, env_request(prefix)}
  defp command_request("load", ""), do: {:error, ",load expects a file"}
  defp command_request("load", file), do: {:ok, load_request(file)}

  defp command_request(name, "") when name in ["expand", "time"],
    do: {:error, ",#{name} expects a form"}

  defp command_request("expand", source), do: {:ok, expand_request(source)}
  defp command_request("time", source), do: {:ok, time_request(source)}

  defp command_request(name, _args),
    do: {:error, "unknown command ,#{name}. ,help lists the commands"}

  # Requests are functions the evaluator applies to the session. Each
  # returns the text to write and the next session.

  defp eval_request(source) do
    fn session ->
      case Session.eval(session, source) do
        {:ok, value, session} -> {value_line(value), session}
        {:error, e, session} -> {error_text(e, source), session}
      end
    end
  end

  defp time_request(source) do
    fn session ->
      {:reductions, reductions} = Process.info(self(), :reductions)
      started = System.monotonic_time(:microsecond)
      result = Session.eval(session, source)
      elapsed = System.monotonic_time(:microsecond) - started
      {:reductions, reductions_after} = Process.info(self(), :reductions)

      cost =
        "; #{:erlang.float_to_binary(elapsed / 1000, decimals: 1)}ms, " <>
          "#{reductions_after - reductions} reductions\n"

      case result do
        {:ok, :unspecified, session} -> {cost, session}
        {:ok, value, session} -> {[Value.write(value), "  ", cost], session}
        {:error, e, session} -> {[error_text(e, source), cost], session}
      end
    end
  end

  defp expand_request(source) do
    fn session ->
      case Schooner.expand(source, Session.environment(session)) do
        {:ok, forms} -> {[Enum.map_join(forms, "\n\n", &Pretty.format/1), "\n"], session}
        {:error, e} -> {error_text(e, source), session}
      end
    end
  end

  defp load_request(file) do
    fn session ->
      case File.read(file) do
        {:ok, source} ->
          load(session, source, file)

        {:error, reason} ->
          {"error: could not read #{file}: #{:file.format_error(reason)}\n", session}
      end
    end
  end

  defp load(session, source, file) do
    case Session.eval(session, source, file: file) do
      {:ok, _value, session} ->
        {[], session}

      {:error, e, session} ->
        {["error: ", Schooner.format_error(e, source: source), "\n"], session}
    end
  end

  defp env_request(prefix) do
    fn session ->
      bindings = Enum.filter(Session.bindings(session), &String.starts_with?(&1.name, prefix))
      {env_text(bindings, prefix), session}
    end
  end

  defp value_line(:unspecified), do: []
  defp value_line(value), do: [Value.write(value), "\n"]

  # An error in a one-line entry is shown without its location, which
  # is always on line 1. One in a longer entry is shown with the line
  # it is on.
  defp error_text(e, source) do
    text =
      if String.contains?(source, "\n") do
        Schooner.format_error(e, source: source)
      else
        e |> without_location() |> Schooner.format_error()
      end

    ["error: ", text, "\n"]
  end

  defp without_location(%{location: _} = e), do: %{e | location: nil}
  defp without_location(e), do: e

  defp env_text([], ""), do: "nothing is bound\n"
  defp env_text([], prefix), do: "nothing bound starts with #{prefix}\n"

  defp env_text(bindings, _prefix) do
    rows =
      Enum.map(bindings, fn binding ->
        library = if binding.library, do: Library.render_name(binding.library), else: ""
        {binding.name, library, describe(binding)}
      end)

    name_width = rows |> Enum.map(&String.length(elem(&1, 0))) |> Enum.max()
    library_width = rows |> Enum.map(&String.length(elem(&1, 1))) |> Enum.max()

    Enum.map(rows, fn {name, library, description} ->
      columns =
        if library_width == 0,
          do: [String.pad_trailing(name, name_width + 2), description],
          else: [
            String.pad_trailing(name, name_width + 2),
            String.pad_trailing(library, library_width + 2),
            description
          ]

      [columns |> IO.iodata_to_binary() |> String.trim_trailing(), "\n"]
    end)
  end

  defp describe(%{kind: :macro}), do: "macro"

  defp describe(%{kind: :procedure, value: {:parameter, _, _, _}}), do: "parameter"

  defp describe(%{kind: :procedure, value: value}) do
    case arity(value) do
      nil -> "procedure"
      arity -> "procedure, " <> arity
    end
  end

  defp describe(%{value: value}) do
    written = Value.write(value)
    if String.length(written) > 40, do: String.slice(written, 0, 39) <> "…", else: written
  end

  defp arity({:primitive, _, spec, _}), do: arity_text(spec)
  defp arity({:closure, {:fixed, n, _}, _, _, _}), do: arity_text(n)
  defp arity({:closure, {:fixed_rest, n, _, _}, _, _, _}), do: arity_text({:at_least, n})
  defp arity({:closure, {:any, _}, _, _, _}), do: arity_text({:at_least, 0})
  defp arity(_), do: nil

  defp arity_text(1), do: "1 arg"
  defp arity_text(n) when is_integer(n), do: "#{n} args"
  defp arity_text({:at_least, n}), do: "#{n}+ args"
  defp arity_text({:between, low, high}), do: "#{low}-#{high} args"
  defp arity_text(_), do: nil

  # ---------------------------------------------------------------------------
  # The evaluator
  # ---------------------------------------------------------------------------

  defp start_evaluator(state, init) do
    repl = self()
    ref = make_ref()
    leader = if is_pid(state.output), do: state.output, else: Process.group_leader()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.group_leader(self(), leader)
        evaluator_init(repl, ref, init)
      end)

    track({pid, monitor})

    receive do
      {^ref, :ok, snapshot} ->
        %{state | evaluator: {pid, monitor}, snapshot: snapshot}

      {^ref, {:error, kind, reason, stacktrace}, _snapshot} ->
        Process.demonitor(monitor, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        exit(reason)
    end
  end

  defp evaluator_init(repl, ref, {:build, environment, opts}) do
    guard(repl)
    session = Session.new(environment.(), opts)
    send(repl, {ref, :ok, snapshot(session)})
    evaluator_loop(repl, session)
  catch
    kind, reason ->
      send(repl, {ref, {:error, kind, reason, __STACKTRACE__}, nil})
      # Exit abnormally, so the guard linked to this process goes too.
      exit({:shutdown, :no_environment})
  end

  defp evaluator_init(repl, ref, {:restore, {session, dictionary}}) do
    guard(repl)
    Enum.each(dictionary, fn {key, value} -> Process.put(key, value) end)
    send(repl, {ref, :ok, {session, dictionary}})
    evaluator_loop(repl, session)
  end

  defp evaluator_loop(repl, session) do
    receive do
      {:request, ref, request} ->
        {text, session} =
          try do
            request.(session)
          catch
            kind, reason -> {["error: ", Exception.format(kind, reason, __STACKTRACE__)], session}
          end

        send(repl, {ref, text, snapshot(session)})
        evaluator_loop(repl, session)
    end
  end

  # Stop this evaluator when the REPL goes, even in the middle of an
  # evaluation, when a message would wait unread: a process linked to
  # it kills it when the REPL exits. Being linked, it goes when the
  # evaluator does.
  defp guard(repl) do
    evaluator = self()

    spawn_link(fn ->
      monitor = Process.monitor(repl)

      receive do
        # A kill, since the evaluator may trap exits.
        {:DOWN, ^monitor, :process, ^repl, _reason} -> Process.exit(evaluator, :kill)
      end
    end)
  end

  # The session and this process's dictionary, without the entries the
  # runtime keeps there (`$ancestors`, `$initial_call`, ...).
  defp snapshot(session) do
    dictionary =
      Enum.reject(Process.get(), fn {key, _} ->
        is_atom(key) and String.starts_with?(Atom.to_string(key), "$")
      end)

    {session, dictionary}
  end

  # Have the evaluator run `request`, and return the text it produced.
  # In editor mode, Ctrl-C meanwhile interrupts it.
  defp request(state, request) do
    {pid, monitor} = state.evaluator
    ref = make_ref()
    send(pid, {:request, ref, request})
    reader = state.reader

    receive do
      {^ref, text, snapshot} ->
        {text, %{state | snapshot: snapshot}}

      {:repl_input, ^reader, "\x03"} when reader != nil ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
        {"interrupted\n", restart(state)}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {"error: the evaluator exited: #{Exception.format_exit(reason)}\n", restart(state)}
    end
  end

  defp restart(state), do: start_evaluator(state, {:restore, state.snapshot})

  # The evaluators and the reader this REPL starts are kept in its
  # process dictionary, so that `run/1` stops them however it ends,
  # including by an exception the caller catches.
  defp track(worker), do: Process.put(@workers, [worker | Process.get(@workers, [])])

  defp stop_workers(previous) do
    Enum.each(Process.get(@workers, []), fn
      {pid, :link} ->
        Process.unlink(pid)
        Process.exit(pid, :kill)

      {pid, monitor} ->
        Process.demonitor(monitor, [:flush])
        Process.exit(pid, :kill)
    end)

    if previous, do: Process.put(@workers, previous), else: Process.delete(@workers)
  end

  defp write(state, iodata), do: IO.write(state.output, iodata)
end
