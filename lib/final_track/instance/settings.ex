defmodule FinalTrack.Instance.Settings do
  @moduledoc "The one row of server-wide settings admins edit (`FinalTrack.Instance`)."
  use FinalTrack.Schema
  import Ecto.Changeset

  schema "instance_settings" do
    field :node_name, :string
    field :node_description, :string

    timestamps()
  end

  @doc "Blank fields are stored as nil, meaning: use the environment's, then the default."
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:node_name, :node_description])
    # Cleared fields arrive as nil (Ecto's empty value): nothing to trim.
    |> update_change(:node_name, &trim/1)
    |> update_change(:node_description, &trim/1)
    |> validate_length(:node_name, max: 80)
    |> validate_length(:node_description, max: 500)
  end

  defp trim(nil), do: nil
  defp trim(text), do: String.trim(text)
end
