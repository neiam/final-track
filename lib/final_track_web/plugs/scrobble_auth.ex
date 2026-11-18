defmodule FinalTrackWeb.Plugs.ScrobbleAuth do
  @moduledoc """
  Authenticates scrobbling clients by `Authorization: Bearer <token>` (a
  token minted on the Scrobbling clients page) and assigns `current_scope`
  for its user. Every failure (missing, malformed or unknown token) is the
  same 401, so the endpoint can't be used to probe for tokens.
  """
  import Plug.Conn

  alias FinalTrack.Accounts.Scope
  alias FinalTrack.Scrobbles

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- Scrobbles.verify_token(String.trim(token)) do
      assign(conn, :current_scope, Scope.for_user(user))
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end
