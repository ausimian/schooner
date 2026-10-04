defmodule Schooner.REPLTest do
  use ExUnit.Case, async: true

  alias Schooner.Environment
  alias Schooner.Host
  alias Schooner.REPL

  @moduletag :tmp_dir

  defmodule FakeTerminal do
    @moduledoc false

    # An input device that hands out, a character at a time, what the
    # test has fed it, and waits when there is nothing to read, as a
    # terminal does. Closing it ends the input.

    def start, do: spawn_link(fn -> loop("", [], false) end)
    def feed(device, data), do: send(device, {:feed, data})
    def close(device), do: send(device, :close)

    defp loop(buffer, waiting, closed?) do
      receive do
        {:feed, data} ->
          serve(buffer <> data, waiting, closed?)

        :close ->
          serve(buffer, waiting, true)

        {:io_request, from, ref, {:get_chars, _encoding, _prompt, 1}} ->
          serve(buffer, waiting ++ [{from, ref}], closed?)

        {:io_request, from, ref, _request} ->
          send(from, {:io_reply, ref, {:error, :enotsup}})
          loop(buffer, waiting, closed?)
      end
    end

    defp serve(buffer, [{from, ref} | waiting], closed?) when buffer != "" do
      {char, rest} = String.next_grapheme(buffer)
      send(from, {:io_reply, ref, char})
      serve(rest, waiting, closed?)
    end

    defp serve("", [{from, ref} | waiting], true) do
      send(from, {:io_reply, ref, :eof})
      serve("", waiting, true)
    end

    defp serve(buffer, waiting, closed?), do: loop(buffer, waiting, closed?)
  end

  defp scripts_environment do
    Environment.new(
      standard_libraries: [:base, :char, :write],
      pre_imports: [["scheme", "base"]],
      libraries: [
        Host.library(name: ["myapp", "catalog"], primitives: [{"unit-price", 1, fn _ -> 10 end}])
      ]
    )
  end

  # Run the REPL in line mode over `input`, echoing it, and return what
  # it wrote.
  defp repl(input, opts \\ []) do
    {:ok, in_device} = StringIO.open(input)
    {:ok, out_device} = StringIO.open("")

    opts =
      Keyword.merge(
        [
          input: in_device,
          output: out_device,
          echo: true,
          environment: &scripts_environment/0
        ],
        opts
      )

    assert REPL.run(opts) == :ok
    {_, output} = StringIO.contents(out_device)
    output
  end

  describe "line mode" do
    test "prints each entry's value, and nothing for a definition" do
      assert repl("""
             (define x 41)
             (+ x 1)
             "hi"
             'sym
             """) == """
             schooner> (define x 41)
             schooner> (+ x 1)
             42
             schooner> "hi"
             "hi"
             schooner> 'sym
             sym
             schooner> \n\
             """
    end

    test "reads an entry that ends inside an open form on more lines" do
      assert repl("""
             (define (f x)
               (* x
                  2))
             (f 4)
             """) == """
             schooner> (define (f x)
                  ...>   (* x
                  ...>      2))
             schooner> (f 4)
             8
             schooner> \n\
             """
    end

    test "prints an error and keeps going" do
      output =
        repl("""
        (define x 1)
        (car x)
        (nope)
        (+ 1
        x)
        x
        """)

      assert output =~ "schooner> (car x)\nerror: type error in `car`: expected pair, got 1\n"
      assert output =~ "schooner> (nope)\nerror: unbound variable: nope\n"
      assert output =~ "schooner> (+ 1\n     ...> x)\n2\n"
      assert output =~ "schooner> x\n1\n"
    end

    test "an error in a multi-line entry shows the line it's on" do
      output =
        repl("""
        (list 1
              y)
        """)

      assert output =~ """
             error: 2:7: unbound variable: y
               |
             2 |       y)
               |       ^
             """
    end

    test "evaluates every form in an entry, printing the last value" do
      assert repl("(define a 1) (define b 2) (+ a b)\n") =~
               "schooner> (define a 1) (define b 2) (+ a b)\n3\n"
    end

    test "imports and macros persist" do
      output =
        repl("""
        (char-upcase #\\a)
        (import (scheme char))
        (char-upcase #\\a)
        (define-syntax swap (syntax-rules () ((_ a b) (list b a))))
        (swap 1 2)
        """)

      assert output =~ "error: unbound variable: char-upcase\n"
      assert output =~ "schooner> (char-upcase #\\a)\n#\\A\n"
      assert output =~ "schooner> (swap 1 2)\n(2 1)\n"
    end

    test "a blank entry prompts again" do
      assert repl("\n  \n1\n") == "schooner> \nschooner>   \nschooner> 1\n1\nschooner> \n"
    end

    test "unfinished source at the end of the input is reported" do
      assert repl("(+ 1\n") =~ "     ...> \nerror: unterminated list"
    end

    test "the banner comes first" do
      assert repl("", banner: "Hello.") == "Hello.\nschooner> \n"
    end

    test "a host function that raises is reported" do
      environment = fn ->
        Environment.new(
          pre_imports: [["scheme", "base"]],
          libraries: [
            Host.library(name: [], primitives: [{"crash", 0, fn [] -> raise "boom" end}])
          ]
        )
      end

      output = repl("(define x 1)\n(crash)\nx\n", environment: environment)
      assert output =~ "schooner> (crash)\nerror: ** (RuntimeError) boom\n"
      assert output =~ "schooner> x\n1\n"
    end

    test "when the evaluator dies, the session is restored as it was before the entry" do
      environment = fn ->
        Environment.new(
          pre_imports: [["scheme", "base"]],
          libraries: [
            Host.library(
              name: [],
              primitives: [{"die", 0, fn [] -> Process.exit(self(), :kill) end}]
            )
          ]
        )
      end

      output = repl("(define x 1)\n(define y 2) (die)\nx\ny\n", environment: environment)
      assert output =~ "(die)\nerror: the evaluator exited: killed\n"
      assert output =~ "schooner> x\n1\n"
      assert output =~ "schooner> y\nerror: unbound variable: y\n"
    end

    test "the evaluator stops when the REPL does, even mid-evaluation" do
      test = self()

      environment = fn ->
        hang = fn [] -> send(test, {:evaluator, self()}) && Process.sleep(:infinity) end
        Environment.new(libraries: [Host.library(name: [], primitives: [{"hang", 0, hang}])])
      end

      repl = spawn(fn -> repl("(hang)\n", environment: environment) end)
      assert_receive {:evaluator, evaluator}, 5000
      monitor = Process.monitor(evaluator)

      Process.exit(repl, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^evaluator, _}, 5000
    end

    test "the environment function runs in the evaluator, and its errors are raised" do
      test = self()
      repl("", environment: fn -> send(test, {:built_in, self()}) && scripts_environment() end)
      assert_received {:built_in, pid}
      assert pid != self()

      assert_raise RuntimeError, "no environment", fn ->
        repl("", environment: fn -> raise "no environment" end)
      end
    end

    test "debug: true in the session options shows backtraces" do
      output = repl("(define (f x) (car x))\n(f 1)\n", session: [debug: true])
      assert output =~ "error: type error in `car`: expected pair, got 1\n\nScheme backtrace"
    end

    test ":load evaluates files before the first prompt", %{tmp_dir: dir} do
      good = Path.join(dir, "good.scm")
      bad = Path.join(dir, "bad.scm")
      File.write!(good, "(define (double x) (* 2 x))")
      File.write!(bad, "(define z 1)\n(car w)")

      output = repl("(double z)\n", load: [good, bad])

      assert output =~ """
             error: #{bad}:2:6: unbound variable: w
               |
             2 | (car w)
               |      ^
             """

      assert output =~ "schooner> (double z)\n2\n"
    end
  end

  describe "commands" do
    test ",quit leaves" do
      assert repl(",quit\n1\n") == "schooner> ,quit\n"
    end

    test ",help lists the commands" do
      output = repl(",help\n")
      assert output =~ ",env [prefix]"
      assert output =~ ",quit"
      refute output =~ "Tab re-indents"
    end

    test ",env lists bindings with their library and what they are" do
      output =
        repl("""
        (import (myapp catalog))
        (define (two a b) b)
        (define (any . xs) xs)
        (define n 42)
        (define-syntax m (syntax-rules () ((_) 1)))
        ,env unit
        ,env tw
        ,env any
        ,env n
        ,env m
        ,env vector-f
        ,env zzz
        """)

      assert output =~ ",env unit\nunit-price  (myapp catalog)  procedure, 1 arg\n"
      assert output =~ ",env tw\ntwo  procedure, 2 args\n"
      assert output =~ ",env any\nany  procedure, 0+ args\n"
      assert output =~ ~r/,env n\nn {30}42\nnegative\? {7}\(scheme base\)  procedure, 1 arg\n/

      assert output =~
               ~r/,env m\nm +macro\nmake-bytevector  \(scheme base\)  procedure, 1-2 args\n/

      assert output =~ ",env vector-f\nvector-for-each  (scheme base)  procedure, 2+ args\n"
      assert output =~ ",env zzz\nnothing bound starts with zzz\n"
    end

    test ",env without a prefix lists everything in scope" do
      output = repl(",env\n")
      assert output =~ ~r/\ncar +\(scheme base\) +procedure, 1 arg\n/
      assert output =~ ~r/\nwhen +\(scheme base\) +macro\n/
      refute output =~ "unit-price"
    end

    test ",expand shows the expansion with the session's macros" do
      output =
        repl("""
        (define-syntax twice (syntax-rules () ((_ e) (begin e e))))
        ,expand (when ok
          (twice (go)))
        ,expand (if)
        """)

      assert output =~ "     ...>   (twice (go)))\n(if ok (begin (begin (go) (go))))\n"
      assert output =~ ",expand (if)\nerror: malformed `if`"
    end

    test ",time evaluates and reports the cost" do
      output = repl("(define x 2)\n,time (* x 21)\n,time (define y 1)\n,time (car 1)\ny\n")
      assert output =~ ~r/,time \(\* x 21\)\n42  ; \d+\.\dms, \d+ reductions\n/
      assert output =~ ~r/,time \(define y 1\)\n; \d+\.\dms, \d+ reductions\n/

      assert output =~
               ~r/,time \(car 1\)\nerror: type error in `car`: expected pair, got 1\n; \d+\.\dms/

      assert output =~ "schooner> y\n1\n"
    end

    test ",load evaluates a file into the session", %{tmp_dir: dir} do
      path = Path.join(dir, "lib.scm")
      File.write!(path, "(define (triple x) (* 3 x))")

      output = repl(",load #{path}\n(triple 2)\n,load #{dir}/missing.scm\n")
      assert output =~ "schooner> (triple 2)\n6\n"
      assert output =~ "error: could not read #{dir}/missing.scm: no such file or directory\n"
    end

    test "commands missing their argument, and unknown ones, are errors" do
      output = repl(",load\n,time\n,expand\n,frob\n")
      assert output =~ ",load\nerror: ,load expects a file\n"
      assert output =~ ",time\nerror: ,time expects a form\n"
      assert output =~ ",expand\nerror: ,expand expects a form\n"
      assert output =~ ",frob\nerror: unknown command ,frob. ,help lists the commands\n"
    end
  end

  describe "editor mode" do
    # Start the REPL in editor mode reading from a fake terminal, and
    # return the terminal, the output device and the task running it.
    defp start_editor(opts \\ []) do
      terminal = FakeTerminal.start()
      {:ok, out_device} = StringIO.open("")

      task =
        Task.async(fn ->
          REPL.run(
            [
              input: terminal,
              output: out_device,
              mode: :editor,
              environment: &scripts_environment/0
            ] ++ opts
          )
        end)

      {terminal, out_device, task}
    end

    # What the REPL wrote, without the escape sequences and carriage
    # returns the editor redraws with. Each redraw is left in, so an
    # entry appears once for each key typed into it.
    defp output(out_device) do
      out_device
      |> StringIO.contents()
      |> elem(1)
      |> String.replace(~r/\e\[[0-9;?]*[A-Za-z]|\r/, "")
    end

    # Wait until the output contains `count` copies of `text`.
    defp await_output(out_device, text, count \\ 1) do
      deadline = System.monotonic_time(:millisecond) + 5000

      Stream.repeatedly(fn -> output(out_device) end)
      |> Enum.find(fn output ->
        found = output |> String.split(text) |> length() |> Kernel.-(1)

        cond do
          found >= count ->
            true

          System.monotonic_time(:millisecond) > deadline ->
            flunk("no #{inspect(text)} in:\n#{output}")

          true ->
            Process.sleep(10) && false
        end
      end)
    end

    test "indents continuation lines and evaluates the entry" do
      {terminal, out, task} = start_editor()
      FakeTerminal.feed(terminal, "(define (f x)\r(* x 2))\r(f 4)\r\x04")

      assert Task.await(task) == :ok
      output = output(out)
      assert output =~ "schooner> (define (f x)\n     ...>   (* x 2))"
      assert output =~ "(f 4)\n8\n"
    end

    test "Ctrl-C interrupts an evaluation and keeps the session" do
      {terminal, out, task} = start_editor()
      FakeTerminal.feed(terminal, "(define x 5)\r")
      await_output(out, "schooner> ", 2)

      FakeTerminal.feed(terminal, "(let loop () (loop))\r\x03x\r")
      await_output(out, "\n5\n")
      FakeTerminal.close(terminal)

      assert Task.await(task) == :ok
      assert output(out) =~ "(loop))\ninterrupted\n"
    end

    test "Ctrl-C interrupts a file being loaded", %{tmp_dir: dir} do
      path = Path.join(dir, "loop.scm")
      File.write!(path, "(define y 1) (let loop () (loop))")

      {terminal, out, task} = start_editor(load: [path])
      FakeTerminal.feed(terminal, "\x03")
      await_output(out, "interrupted\n")
      FakeTerminal.feed(terminal, "y\r\x04")

      assert Task.await(task) == :ok
      # The session is as it was before the file.
      assert output(out) =~ "schooner> y\nerror: unbound variable: y\n"
    end

    test "Ctrl-C at the prompt discards the entry" do
      {terminal, out, task} = start_editor()
      FakeTerminal.feed(terminal, "(car\x03(+ 1 2)\r\x04")

      assert Task.await(task) == :ok
      assert output(out) =~ "^C\nschooner> "
      assert output(out) =~ "\n3\n"
    end

    test ",help mentions the keys" do
      {terminal, out, task} = start_editor()
      FakeTerminal.feed(terminal, ",help\r,quit\r")

      assert Task.await(task) == :ok
      assert output(out) =~ "Tab re-indents"
    end

    test "the end of the input leaves" do
      {terminal, _out, task} = start_editor()
      FakeTerminal.close(terminal)
      assert Task.await(task) == :ok
    end
  end
end
