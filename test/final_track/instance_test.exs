defmodule FinalTrack.InstanceTest do
  # Changes app config: not async.
  use FinalTrack.DataCase, async: false

  alias FinalTrack.Instance

  setup do
    on_exit(fn -> Application.delete_env(:final_track, Instance) end)
  end

  test "admin's value, else the environment's, else the default" do
    assert Instance.node_name() == "Final Track"
    assert Instance.node_description() =~ "scrobble server"

    Application.put_env(:final_track, Instance, node_name: "Tunes", node_description: "Ours.")
    assert Instance.node_name() == "Tunes"
    assert Instance.defaults() == %{node_name: "Tunes", node_description: "Ours."}

    {:ok, _} = Instance.update_settings(%{node_name: "  The Den ", node_description: ""})
    assert Instance.node_name() == "The Den"
    # Left empty: the environment's.
    assert Instance.node_description() == "Ours."

    {:ok, _} = Instance.update_settings(%{node_name: ""})
    assert Instance.node_name() == "Tunes"
  end

  test "limits" do
    assert {:error, cs} = Instance.update_settings(%{node_name: String.duplicate("x", 81)})
    assert errors_on(cs).node_name != []
  end
end
