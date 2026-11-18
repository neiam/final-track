defmodule FinalTrack.Instance do
  @moduledoc """
  What this server calls itself: the node name and description that
  NodeInfo reports and the instance's own fediverse actor carries.

  Each comes from, in order: what an admin set on the Instance page
  (`instance_settings`), the environment (`FINAL_TRACK_NODE_NAME`,
  `FINAL_TRACK_NODE_DESCRIPTION`, via `config :final_track,
  FinalTrack.Instance`), then the defaults here.
  """
  import Ecto.Query, only: [from: 2]

  alias FinalTrack.Instance.Settings
  alias FinalTrack.Repo

  @default_name "Final Track"
  @default_description "A self-hosted scrobble server: what its members have been playing."

  defp config, do: Application.get_env(:final_track, __MODULE__, [])

  @doc "The node name: admin's, else the environment's, else \"#{@default_name}\"."
  def node_name, do: pick(settings().node_name, config()[:node_name], @default_name)

  @doc "The node description: admin's, else the environment's, else the default."
  def node_description,
    do: pick(settings().node_description, config()[:node_description], @default_description)

  @doc "What each falls back to when the admin field is empty (the environment's, or the default)."
  def defaults do
    %{
      node_name: pick(nil, config()[:node_name], @default_name),
      node_description: pick(nil, config()[:node_description], @default_description)
    }
  end

  @doc "The stored settings (an unsaved, empty row if none yet)."
  def settings do
    Repo.one(from(s in Settings, order_by: s.inserted_at, limit: 1)) || %Settings{}
  end

  def change_settings(attrs \\ %{}), do: Settings.changeset(settings(), attrs)

  def update_settings(attrs),
    do: settings() |> Settings.changeset(attrs) |> Repo.insert_or_update()

  defp pick(set, env, default) do
    Enum.find([set, env], default, &(is_binary(&1) and String.trim(&1) != ""))
  end
end
