defmodule Schooner.Primitives.Record do
  @moduledoc """
  Runtime primitives that back the `define-record-type` form.

  The expander emits calls to these primitives — they are not part
  of the user-facing language proper. Each call carries the record
  type's identity (a fresh `{:record_type, name, unique_int}` term
  minted at expansion time) so the primitive can verify that the
  value it was handed is actually an instance of that type before
  doing anything else.

  Since type identity comes from a per-expansion gensym, two
  `define-record-type` forms with the same record name in
  different lexical scopes mint different identities; the
  predicate from one scope returns `#f` for an instance from the
  other, even though the renderings look identical.
  """

  alias Schooner.Env
  alias Schooner.Primitive.Error
  alias Schooner.Value

  # Names exposed publicly so the expander emits exactly the strings
  # this module registers. Single source of truth — adding a new
  # record primitive only requires updating `specs/0`.
  @instance_name "%record-instance"
  @predicate_name "%record-of?"
  @ref_name "%record-ref"

  @doc "Symbol name of the record-construction primitive."
  @spec instance_name() :: binary()
  def instance_name, do: @instance_name

  @doc "Symbol name of the record-type-predicate primitive."
  @spec predicate_name() :: binary()
  def predicate_name, do: @predicate_name

  @doc "Symbol name of the record-field-access primitive."
  @spec ref_name() :: binary()
  def ref_name, do: @ref_name

  @doc """
  Define every record-machinery primitive on `env`. Returns the
  same env (the global table is mutated in place — consistent with
  `Env.define/3`).
  """
  @spec register_into(Env.t()) :: Env.t()
  def register_into(%Env{} = env) do
    Enum.reduce(specs(), env, fn {name, arity, fun}, acc ->
      Env.define(acc, name, Value.primitive(name, arity, fun))
    end)
  end

  defp specs do
    [
      {@instance_name, {:at_least, 1}, &record_instance/1},
      {@predicate_name, 2, &record_of?/1},
      {@ref_name, 3, &record_ref/1}
    ]
  end

  # Construct a record. The first arg is the type identity; the
  # rest become the field tuple in order. The expander wraps this
  # in a lambda so the user-facing constructor checks arity.
  defp record_instance([type_id | fields]) do
    Value.record(type_id, List.to_tuple(fields))
  end

  defp record_of?([type_id, {:record, instance_id, _}]) do
    Value.bool(type_id === instance_id)
  end

  defp record_of?([_type_id, _]), do: Value.bool(false)

  defp record_ref([type_id, {:record, instance_id, fields}, index])
       when is_integer(index) and index >= 0 do
    if type_id === instance_id do
      elem(fields, index)
    else
      raise Error, reason: {:wrong_record_type, "%record-ref", type_name(type_id)}
    end
  end

  defp record_ref([type_id, _other, _index]) do
    raise Error, reason: {:wrong_record_type, "%record-ref", type_name(type_id)}
  end

  defp type_name({:record_type, name, _}), do: name
  defp type_name(other), do: inspect(other)
end
