defmodule FinalTrack.Repo.Migrations.CreateInstanceSettings do
  use Ecto.Migration

  # What admins set for the whole server (FinalTrack.Instance). One row,
  # created on first save; NULL fields fall back to the environment's
  # FINAL_TRACK_NODE_NAME / FINAL_TRACK_NODE_DESCRIPTION, then defaults.
  def change do
    create table(:instance_settings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :node_name, :string
      add :node_description, :text

      timestamps(type: :utc_datetime)
    end
  end
end
