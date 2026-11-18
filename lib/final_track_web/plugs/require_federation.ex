defmodule FinalTrackWeb.Plugs.RequireFederation do
  @moduledoc "404 for every ActivityPub route while federation is off (the default)."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    if FinalTrack.Federation.enabled?(),
      do: conn,
      else: conn |> send_resp(404, "Not Found") |> halt()
  end
end
