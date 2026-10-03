defmodule Schooner.Primitives.Record do
  @moduledoc """
  Runtime primitives that back the `define-record-type` form.

  The expander emits calls to these primitives; they are not part of
  the user-facing language. Each call carries the record type's
  identity (a fresh `{:record_type, name, unique_int}` term minted at
  expansion time) so the primitive can check that its argument is an
  instance of that type.

  Because each expansion mints a new identity, two
  `define-record-type` forms with the same record name produce
  distinct types: the predicate from one returns `#f` for an instance
  of the other, even though both print the same way.
  """

  alias Schooner.Primitive.Error
  alias Schooner.Value

  # Exposed through the functions below so the expander emits exactly
  # the names this module registers.
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
  Return every record-machinery primitive as a `{name, arity, fun}`
  tuple. Consumed by `Schooner.Library.Standard` as part of the
  `(scheme base)` assembly (record machinery is in r7rs §5.5 of
  base).
  """
  @spec specs() :: [{binary(), Value.arity_spec(), fun()}]
  def specs do
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
