defmodule Schooner.REPL.Terminal do
  @moduledoc false

  # Puts the terminal on standard input into the mode the line editor
  # needs, and back.
  #
  # The editor reads a key at a time, so the terminal must not buffer
  # lines or echo: `:shell.start_interactive({:noshell, :raw})` does
  # that. Raw mode also stops the terminal turning "\n" into "\r\n" on
  # output, but leaves Ctrl-C raising SIGINT, which opens the BEAM's
  # BREAK menu instead of reaching the REPL. `stty`, run on the
  # terminal's device, turns the first back on and the second off, so
  # that Ctrl-C arrives as a key and can interrupt an evaluation.
  #
  # Anything that fails (standard input isn't a terminal, there's no
  # `stty` or `ps`, or a shell already owns the terminal, as under
  # `iex -S mix`) leaves the terminal as it was, and the REPL reads
  # whole lines instead.

  @enforce_keys [:device, :saved]
  defstruct [:device, :saved]

  @type t :: %__MODULE__{device: binary(), saved: binary()}

  @doc "Put the terminal into editing mode, or return `:error`."
  @spec open() :: {:ok, t()} | :error
  def open do
    with true <- terminal?(),
         {:ok, device} <- device(),
         {:ok, saved} <- stty(device, "-g"),
         :ok <- interactive(:raw) do
      case stty(device, "-isig opost onlcr") do
        {:ok, _} ->
          # Bracketed paste: the terminal marks pasted text, so that
          # its newlines aren't taken as Enter.
          IO.write("\e[?2004h")
          {:ok, %__MODULE__{device: device, saved: String.trim(saved)}}

        :error ->
          interactive(:cooked)
          :error
      end
    else
      _ -> :error
    end
  end

  @doc "Put the terminal back as `open/0` found it."
  @spec close(t()) :: :ok
  def close(%__MODULE__{device: device, saved: saved}) do
    IO.write("\e[?2004l")
    stty(device, saved)
    interactive(:cooked)
    :ok
  end

  @doc "The width of the terminal on `device`, in columns."
  @spec columns(IO.device()) :: pos_integer()
  def columns(device) do
    # `:stdio` is Elixir's name for the device; Erlang's is `:standard_io`.
    device = if device == :stdio, do: :standard_io, else: device

    case :io.columns(device) do
      {:ok, columns} when columns > 0 -> columns
      _ -> 80
    end
  end

  defp terminal? do
    opts = :io.getopts(:standard_io)
    is_list(opts) and opts[:stdin] == true and opts[:stdout] == true
  end

  # The device file of this process's controlling terminal.
  defp device do
    case cmd("ps", ["-o", "tty=", "-p", System.pid()]) do
      {:ok, out} ->
        name = String.trim(out)
        path = "/dev/" <> name

        if Regex.match?(~r{\A[\w./-]+\z}, name) and File.exists?(path),
          do: {:ok, path},
          else: :error

      :error ->
        :error
    end
  end

  # `stty` reads and sets the terminal on its standard input.
  defp stty(device, args), do: cmd("sh", ["-c", "stty #{args} < #{device}"])

  defp cmd(command, args) do
    case System.cmd(command, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      _ -> :error
    end
  rescue
    ErlangError -> :error
  end

  defp interactive(mode) do
    case :shell.start_interactive({:noshell, mode}) do
      :ok -> :ok
      _ -> :error
    end
  rescue
    UndefinedFunctionError -> :error
  end
end
