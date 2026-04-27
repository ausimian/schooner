defmodule Schooner.Expander do
  @moduledoc """
  Datum-AST → core-AST expansion pass.

  Walks the reader's output, applies `define-syntax` / `let-syntax` /
  `letrec-syntax` bindings to expand macro uses, and leaves only the
  core forms — `quote`, `if`, `lambda`, top-level `define`, `begin`,
  application, and variable reference — for the evaluator to consume.
  Everything else, including all of phase 7's derived forms, lives as
  a `syntax-rules` macro registered in the bootstrap syntax env.

  Hygiene is by alpha-renaming with a fresh per-expansion mark; see
  `Schooner.Expander.SyntaxRules` for the details. The expander's job
  in this module is to drive expansion until a fixed point and to
  shadow macro keywords with `:variable` frames so that an inner
  `let` shadowing the bootstrap `let` does the expected thing.

  ## Top-level vs. internal `define-syntax`

  Top-level `define-syntax` is the supported form. Bodies that mix
  internal `define-syntax` with internal `define` are not yet handled
  — `let-syntax` / `letrec-syntax` cover the in-body needs and the
  spec leaves the internal-define-syntax case off the critical path.
  """

  alias Schooner.Eval.Error
  alias Schooner.Expander.Derived
  alias Schooner.Expander.SyntaxEnv
  alias Schooner.Expander.SyntaxRules
  alias Schooner.Reader
  alias Schooner.Value

  # `letrec*` is intentionally retained as a core form: it backs both
  # user-facing recursive bindings and the internal-define splicing
  # done at evaluation time, and a fully-macroised replacement would
  # need either mutation or a hand-built fix-point combinator.
  @core_specials MapSet.new(~w(quote if lambda define begin set! letrec*))

  @doc """
  Expand a list of top-level forms in `env`. Returns a list of
  expanded forms with all `define-syntax` / `let-syntax` /
  `letrec-syntax` and macro uses resolved to core forms.
  """
  @spec expand_program([Value.t()], SyntaxEnv.t()) :: [Value.t()]
  def expand_program(forms, %SyntaxEnv{} = env) when is_list(forms) do
    {expanded, _env} = expand_top_seq(forms, env, [])
    expanded
  end

  @doc """
  Return the cached bootstrap syntax env containing the derived-form
  macros. Computed lazily on first call and cached via
  `:persistent_term` so that subsequent runs do not re-parse the
  bootstrap source.
  """
  @spec bootstrap_env() :: SyntaxEnv.t()
  def bootstrap_env do
    case :persistent_term.get({__MODULE__, :bootstrap_env}, :unset) do
      :unset ->
        env = build_bootstrap_env()
        :persistent_term.put({__MODULE__, :bootstrap_env}, env)
        env

      env ->
        env
    end
  end

  defp build_bootstrap_env do
    forms = Reader.read_string(Derived.source())
    {_, env} = expand_top_seq(forms, SyntaxEnv.new(), [])
    env
  end

  # ---------------------------------------------------------------------------
  # Top-level sequence
  # ---------------------------------------------------------------------------

  defp expand_top_seq([], env, acc), do: {Enum.reverse(acc), env}

  defp expand_top_seq([form | rest], env, acc) do
    case expand_top(form, env) do
      {:syntax_def, env2} -> expand_top_seq(rest, env2, acc)
      expanded -> expand_top_seq(rest, env, [expanded | acc])
    end
  end

  defp expand_top({:pair, {:sym, "define-syntax"}, tail}, env) do
    {name, transformer} = parse_define_syntax(tail, env)
    {:syntax_def, SyntaxEnv.define_macro(env, name, transformer)}
  end

  defp expand_top({:pair, {:sym, "begin"}, body}, env) do
    case expand_top_begin(body, env, []) do
      {:syntax_def, env2} -> {:syntax_def, env2}
      expanded -> expanded
    end
  end

  defp expand_top(form, env), do: expand(form, env)

  defp expand_top_begin(:null, env, acc) do
    {:pair, {:sym, "begin"}, Value.list(Enum.reverse(acc))}
    |> finalise_top_begin(env, acc)
  end

  defp expand_top_begin({:pair, form, rest}, env, acc) do
    case expand_top(form, env) do
      {:syntax_def, env2} -> expand_top_begin(rest, env2, acc)
      expanded -> expand_top_begin(rest, env, [expanded | acc])
    end
  end

  defp expand_top_begin(_, _env, _acc), do: raise(Error, reason: {:bad_special_form, "begin"})

  defp finalise_top_begin(_form, env, []), do: {:syntax_def, env}

  defp finalise_top_begin(form, _env, _acc), do: form

  # ---------------------------------------------------------------------------
  # Recursive expansion of an arbitrary form
  # ---------------------------------------------------------------------------

  @doc "Expand a single form to a fixed point."
  @spec expand(Value.t(), SyntaxEnv.t()) :: Value.t()
  def expand({:pair, {:sym, "quote"}, _} = form, _env), do: form

  def expand({:pair, {:sym, "lambda"}, tail}, env), do: expand_lambda(tail, env)

  def expand({:pair, {:sym, "define"}, tail}, env), do: expand_define(tail, env)

  def expand({:pair, {:sym, "if"}, tail}, env), do: expand_if(tail, env)

  def expand({:pair, {:sym, "begin"}, tail}, env) do
    {:pair, {:sym, "begin"}, expand_each(tail, env)}
  end

  def expand({:pair, {:sym, "letrec*"}, tail}, env), do: expand_letrec_star(tail, env)

  def expand({:pair, {:sym, "set!"}, _tail}, _env) do
    raise Error, reason: {:bad_special_form, "set!"}
  end

  def expand({:pair, {:sym, "let-syntax"}, tail}, env), do: expand_let_syntax(tail, env)

  def expand({:pair, {:sym, "letrec-syntax"}, tail}, env), do: expand_letrec_syntax(tail, env)

  def expand({:pair, {:sym, "define-syntax"}, _tail}, _env) do
    raise Error, reason: :nested_define_syntax_unsupported
  end

  def expand({:pair, {:sym, "quasiquote"}, _tail} = form, env) do
    expand_quasiquote(form, env, 1)
  end

  def expand({:pair, {:sym, name}, _args} = form, env) do
    case lookup_with_fallback(env, name) do
      {:macro, transformer} ->
        new_form = transformer.(form)
        expand(new_form, env)

      {:special, base} ->
        # A core special form's name appeared with a hygiene mark.
        # Re-dispatch on the canonical name so the special-form
        # clauses above pick it up and emit canonical output.
        canonicalise_special(base, form, env)

      _ ->
        expand_application(form, env)
    end
  end

  def expand({:pair, _head, _tail} = form, env), do: expand_application(form, env)

  def expand({:sym, _} = sym, _env), do: sym
  def expand(:null, _env), do: :null
  def expand(other, _env), do: other

  # ---------------------------------------------------------------------------
  # Special-form expanders
  # ---------------------------------------------------------------------------

  defp expand_application({:pair, head, args}, env) do
    {:pair, expand(head, env), expand_each(args, env)}
  end

  # A core special form's name reached us with a hygiene mark — i.e.
  # a template wrote one of `quote`/`if`/`lambda`/etc. without
  # listing it in `SyntaxRules`'s `@core_keywords`. Re-dispatch on
  # the canonical name so the dedicated handlers fire.
  defp canonicalise_special(base, {:pair, {:sym, _}, tail}, env) do
    expand({:pair, {:sym, base}, tail}, env)
  end

  # Walk the syntax env for `name`. If unbound, strip a hygiene mark
  # and try again. If the stripped name is a known core special form,
  # report that so the caller can re-dispatch on its canonical name.
  defp lookup_with_fallback(env, name) do
    case SyntaxEnv.lookup(env, name) do
      :undefined -> resolve_marked(env, name)
      binding -> binding
    end
  end

  defp resolve_marked(env, name) do
    case SyntaxRules.strip_mark(name) do
      :error -> :undefined
      {:ok, base} -> resolve_base(env, base)
    end
  end

  defp resolve_base(env, base) do
    if MapSet.member?(@core_specials, base) do
      {:special, base}
    else
      case SyntaxEnv.lookup(env, base) do
        {:macro, _} = m -> m
        _ -> :undefined
      end
    end
  end

  defp expand_each(:null, _env), do: :null

  defp expand_each({:pair, h, t}, env) do
    {:pair, expand(h, env), expand_each(t, env)}
  end

  defp expand_each(other, _env), do: other

  defp expand_lambda({:pair, params_form, body}, env) when body != :null do
    inner = SyntaxEnv.push_variables(env, collect_param_names(params_form))
    {:pair, {:sym, "lambda"}, {:pair, params_form, expand_each(body, inner)}}
  end

  defp expand_lambda(_, _env), do: raise(Error, reason: {:bad_special_form, "lambda"})

  defp collect_param_names({:sym, name}), do: [name]
  defp collect_param_names(:null), do: []

  defp collect_param_names({:pair, {:sym, name}, rest}) do
    [name | collect_param_names(rest)]
  end

  defp collect_param_names(_), do: raise(Error, reason: {:bad_special_form, "lambda"})

  defp expand_define({:pair, {:sym, name}, {:pair, expr, :null}}, env) do
    {:pair, {:sym, "define"}, {:pair, {:sym, name}, {:pair, expand(expr, env), :null}}}
  end

  defp expand_define({:pair, {:pair, {:sym, name}, params}, body}, env) when body != :null do
    inner = SyntaxEnv.push_variables(env, collect_param_names(params))
    expanded_body = expand_each(body, inner)

    {:pair, {:sym, "define"}, {:pair, {:pair, {:sym, name}, params}, expanded_body}}
  end

  defp expand_define(_, _env), do: raise(Error, reason: {:bad_special_form, "define"})

  defp expand_if({:pair, test, {:pair, then_e, :null}}, env) do
    {:pair, {:sym, "if"}, {:pair, expand(test, env), {:pair, expand(then_e, env), :null}}}
  end

  defp expand_if({:pair, test, {:pair, then_e, {:pair, else_e, :null}}}, env) do
    {:pair, {:sym, "if"},
     {:pair, expand(test, env), {:pair, expand(then_e, env), {:pair, expand(else_e, env), :null}}}}
  end

  defp expand_if(_, _env), do: raise(Error, reason: {:bad_special_form, "if"})

  defp expand_letrec_star({:pair, bindings_form, body}, env) when body != :null do
    parsed = parse_letrec_bindings(bindings_form, [])
    names = Enum.map(parsed, fn {sym, _} -> sym_name(sym) end)
    inner = SyntaxEnv.push_variables(env, names)

    expanded_bindings =
      parsed
      |> Enum.map(fn {sym, init} ->
        {:pair, sym, {:pair, expand(init, inner), :null}}
      end)
      |> Value.list()

    {:pair, {:sym, "letrec*"}, {:pair, expanded_bindings, expand_each(body, inner)}}
  end

  defp expand_letrec_star(_, _env), do: raise(Error, reason: {:bad_special_form, "letrec*"})

  defp sym_name({:sym, name}), do: name

  # Single walk over the binding list yielding `[{sym, init}, ...]` —
  # used twice by the caller (once to derive the binder names for
  # the syntax-env shadow, once to expand the inits in that
  # already-shadowed env), avoiding the duplicate parse the previous
  # split into `letrec_binding_names/1` and `expand_letrec_bindings/2`
  # required.
  defp parse_letrec_bindings(:null, acc), do: Enum.reverse(acc)

  defp parse_letrec_bindings(
         {:pair, {:pair, {:sym, _} = sym, {:pair, init, :null}}, rest},
         acc
       ) do
    parse_letrec_bindings(rest, [{sym, init} | acc])
  end

  defp parse_letrec_bindings(_, _),
    do: raise(Error, reason: {:bad_special_form, "letrec*"})

  defp expand_let_syntax({:pair, bindings_form, body}, env) when body != :null do
    bindings = parse_syntax_bindings(bindings_form, env, "let-syntax")
    inner = SyntaxEnv.push_macros(env, bindings)
    expanded = expand_each(body, inner)
    wrap_body_as_form("let-syntax", expanded)
  end

  defp expand_let_syntax(_, _env), do: raise(Error, reason: {:bad_special_form, "let-syntax"})

  defp expand_letrec_syntax({:pair, bindings_form, body}, env) when body != :null do
    # Collect names first; compile transformers in an env that already
    # knows about all the new macro names so a transformer can refer to
    # its peers (mutually recursive macros).
    names = collect_macro_binding_names(bindings_form, "letrec-syntax")

    placeholder =
      Enum.map(
        names,
        &{&1, fn _ -> raise Error, reason: {:bad_special_form, "letrec-syntax"} end}
      )

    rec_env = SyntaxEnv.push_macros(env, placeholder)
    bindings = parse_syntax_bindings(bindings_form, rec_env, "letrec-syntax")
    inner = SyntaxEnv.push_macros(env, bindings)
    expanded = expand_each(body, inner)
    wrap_body_as_form("letrec-syntax", expanded)
  end

  defp expand_letrec_syntax(_, _env),
    do: raise(Error, reason: {:bad_special_form, "letrec-syntax"})

  defp wrap_body_as_form(_ctx, {:pair, single, :null}), do: single
  defp wrap_body_as_form(_ctx, body), do: {:pair, {:sym, "begin"}, body}

  # ---------------------------------------------------------------------------
  # define-syntax parsing
  # ---------------------------------------------------------------------------

  defp parse_define_syntax({:pair, {:sym, name}, {:pair, spec, :null}}, _env) do
    {name, SyntaxRules.compile(spec)}
  end

  defp parse_define_syntax(_, _env),
    do: raise(Error, reason: {:bad_special_form, "define-syntax"})

  defp parse_syntax_bindings(:null, _env, _ctx), do: []

  defp parse_syntax_bindings({:pair, {:pair, {:sym, name}, {:pair, spec, :null}}, rest}, env, ctx) do
    [{name, SyntaxRules.compile(spec)} | parse_syntax_bindings(rest, env, ctx)]
  end

  defp parse_syntax_bindings(_, _env, ctx), do: raise(Error, reason: {:bad_special_form, ctx})

  defp collect_macro_binding_names(:null, _ctx), do: []

  defp collect_macro_binding_names(
         {:pair, {:pair, {:sym, name}, {:pair, _spec, :null}}, rest},
         ctx
       ) do
    [name | collect_macro_binding_names(rest, ctx)]
  end

  defp collect_macro_binding_names(_, ctx), do: raise(Error, reason: {:bad_special_form, ctx})

  # ---------------------------------------------------------------------------
  # Quasiquote — recurse into unquoted positions but leave quoted data
  # ---------------------------------------------------------------------------

  defp expand_quasiquote({:pair, {:sym, "quasiquote"}, {:pair, datum, :null}}, env, level) do
    {:pair, {:sym, "quasiquote"}, {:pair, walk_quasi(datum, env, level), :null}}
  end

  defp expand_quasiquote(_, _env, _level),
    do: raise(Error, reason: {:bad_special_form, "quasiquote"})

  defp walk_quasi({:pair, {:sym, "unquote"}, {:pair, expr, :null}}, env, 1) do
    {:pair, {:sym, "unquote"}, {:pair, expand(expr, env), :null}}
  end

  defp walk_quasi({:pair, {:sym, "unquote"}, {:pair, expr, :null}}, env, n) when n > 1 do
    {:pair, {:sym, "unquote"}, {:pair, walk_quasi(expr, env, n - 1), :null}}
  end

  defp walk_quasi({:pair, {:sym, "unquote-splicing"}, {:pair, expr, :null}}, env, 1) do
    {:pair, {:sym, "unquote-splicing"}, {:pair, expand(expr, env), :null}}
  end

  defp walk_quasi({:pair, {:sym, "unquote-splicing"}, {:pair, expr, :null}}, env, n) when n > 1 do
    {:pair, {:sym, "unquote-splicing"}, {:pair, walk_quasi(expr, env, n - 1), :null}}
  end

  defp walk_quasi({:pair, {:sym, "quasiquote"}, {:pair, expr, :null}}, env, n) do
    {:pair, {:sym, "quasiquote"}, {:pair, walk_quasi(expr, env, n + 1), :null}}
  end

  defp walk_quasi({:pair, h, t}, env, level) do
    {:pair, walk_quasi(h, env, level), walk_quasi(t, env, level)}
  end

  defp walk_quasi({:vector, t}, env, level) do
    new_items =
      0..(tuple_size(t) - 1)//1
      |> Enum.map(&walk_quasi(elem(t, &1), env, level))

    {:vector, List.to_tuple(new_items)}
  end

  defp walk_quasi(other, _env, _level), do: other
end
