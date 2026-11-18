defmodule FinalTrack.Schema do
  @moduledoc """
  The base every schema in this app builds on.

  Exists so primary-key type is decided in one place rather than repeated in
  twenty schemas. Keys are UUIDv7 — see `FinalTrack.UUIDv7`.
  """

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema

      @primary_key {:id, FinalTrack.UUIDv7, autogenerate: true}
      @foreign_key_type FinalTrack.UUIDv7
      @timestamps_opts [type: :utc_datetime]
    end
  end
end
