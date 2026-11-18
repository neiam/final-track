defmodule FinalTrackWeb.Api.ScrobbleController do
  @moduledoc """
  The scrobbling API, compatible with Scropple's HTTP backend (and with
  ircd's ScrobbleServ, so one client can feed both).

    * `POST /api/v1/now-playing`: one track object. `204`.
    * `POST /api/v1/scrobble`: one object, a bare array, or
      `{"scrobbles": [...]}`. `200 {"accepted": n, "rejected": m}`, where
      `accepted` counts valid plays (a repeat of one already recorded counts:
      the client may forget it) and `rejected` the invalid ones, which are
      dropped. All invalid is a `422`.

  See `FinalTrack.Scrobbles` for the track fields.
  """
  use FinalTrackWeb, :controller

  alias FinalTrack.Scrobbles

  # A client's offline queue drains in batches; this is plenty.
  @max_batch 500

  def now_playing(conn, params) do
    case Scrobbles.validate_play(single(params)) do
      {:ok, play} ->
        :ok = Scrobbles.set_now_playing(conn.assigns.current_scope.user, play)
        send_resp(conn, :no_content, "")

      {:error, detail} ->
        invalid(conn, detail)
    end
  end

  def create(conn, params) do
    items = list(params)

    if length(items) > @max_batch do
      invalid(conn, "at most #{@max_batch} scrobbles per request")
    else
      {plays, errors} =
        items
        |> Enum.map(&Scrobbles.validate_play/1)
        |> Enum.split_with(&match?({:ok, _}, &1))

      plays = Enum.map(plays, fn {:ok, play} -> play end)

      case {plays, errors} do
        {[], [{:error, detail} | _]} ->
          invalid(conn, detail)

        _ ->
          Scrobbles.record_plays(conn.assigns.current_scope.user, plays)
          json(conn, %{accepted: length(plays), rejected: length(errors)})
      end
    end
  end

  # A bare JSON array arrives under "_json" (Plug.Parsers).
  defp list(%{"_json" => list}) when is_list(list), do: list
  defp list(%{"scrobbles" => list}) when is_list(list), do: list
  defp list(params) when is_map(params), do: [params]

  defp single(%{"_json" => [one | _]}), do: one
  defp single(params), do: params

  defp invalid(conn, detail) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_payload", detail: detail})
  end
end
