defmodule FinalTrack.UUIDv7 do
  @moduledoc """
  A UUID version 7 primary key type.

  Version 7 puts a millisecond Unix timestamp in the leading 48 bits, so ids
  sort by creation time. That keeps the index locality of the integer keys
  this replaced — rows written together stay together on disk — while the
  remaining 74 bits stay random, so an id still reveals nothing about how many
  records exist or who else is in the system.

  Layout, per RFC 9562:

      0                   1                   2                   3
      |unix_ts_ms (48 bits)          |ver(4)|rand_a(12)|var(2)|rand_b(62)|

  Storage and casting are plain `Ecto.UUID` — only generation differs — so
  everything that understands a UUID understands these.
  """

  use Ecto.Type

  # Deliberately :uuid rather than :binary_id. Ecto treats a :binary_id
  # primary key as the *adapter's* to generate, and the Postgres adapter
  # hands back a version 4 UUID — which would quietly undo the point of this
  # type. Declaring :uuid keeps generation here.
  @impl true
  def type, do: :uuid

  @impl true
  defdelegate cast(value), to: Ecto.UUID

  @impl true
  defdelegate load(value), to: Ecto.UUID

  @impl true
  defdelegate dump(value), to: Ecto.UUID

  @impl true
  def embed_as(format), do: Ecto.UUID.embed_as(format)

  @impl true
  def equal?(left, right), do: Ecto.UUID.equal?(left, right)

  @impl true
  def autogenerate, do: generate()

  @doc """
  Generates a UUIDv7 string.
  """

  def generate, do: bingenerate() |> Ecto.UUID.load!()

  @doc """
  Generates a UUIDv7 in its raw 16-byte form.
  """
  # Guarded: a negative or oversized timestamp would silently wrap inside the
  # 48-bit field and produce an id that sorts wrongly forever.
  def bingenerate(timestamp_ms \\ System.system_time(:millisecond))
      when is_integer(timestamp_ms) and timestamp_ms >= 0 and timestamp_ms < 281_474_976_710_656 do
    <<rand_a::12, rand_b::62, _rest::54>> = :crypto.strong_rand_bytes(16)
    <<timestamp_ms::48, 7::4, rand_a::12, 2::2, rand_b::62>>
  end

  @doc """
  The millisecond timestamp embedded in a v7 id.

  Returns `:error` for a UUID of any other version — useful when you need to
  know whether an id predates this scheme.
  """
  def extract_timestamp(uuid) when is_binary(uuid) do
    with {:ok, <<timestamp_ms::48, 7::4, _rest::76>>} <- Ecto.UUID.dump(uuid) do
      {:ok, timestamp_ms}
    else
      _ -> :error
    end
  end
end
