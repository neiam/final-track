defmodule FinalTrackWeb.InviteController do
  @moduledoc """
  The signed-out way on from an invite addressed to an email
  (`UserLive.Registration`): create that account (email confirmed by the
  link, with the chosen password), spend the invite and sign in. A
  controller, since a LiveView can't set the session.

  Under `OIDC_LOGIN_MODE=sso_strict` there's no local password: `sso/2`
  remembers the invite and starts the SSO login, which comes back (refused
  as not invited, and kept pending) to the invite page; `register/2` then
  creates the account without a password and links the pending login to it.
  Without that pending login nothing is created.
  """
  use FinalTrackWeb, :controller

  alias FinalTrack.{Accounts, Repo}
  alias FinalTrackWeb.UserAuth

  def sso(conn, %{"invite" => token, "provider" => id}) when is_binary(token) do
    case NeiamAuth.config(id) do
      {:ok, provider} ->
        conn
        |> put_session(:final_track_invite, token)
        |> redirect(to: "/auth/oidc/#{URI.encode(provider.id)}/login")

      _ ->
        conn
        |> put_flash(:error, "That sign-in isn't available.")
        |> redirect(to: ~p"/users/register?#{[invite: token]}")
    end
  end

  def register(conn, %{"invite" => token} = params) when is_binary(token) do
    if NeiamAuth.local_login_enabled?(),
      do: local_register(conn, token, Map.get(params, "user", %{})),
      else: sso_register(conn, token)
  end

  # sso_strict: the account has no password, and exists only if this
  # browser's pending (not-invited) SSO login links to it.
  defp sso_register(conn, token) do
    result =
      Repo.transact(fn ->
        with {:ok, user} <- Accounts.register_by_invite(token, %{}, password: false) do
          linked = NeiamAuth.link_pending(conn, user)

          if NeiamAuth.identities(user) == [],
            do: {:error, :not_signed_in},
            else: {:ok, {linked, user}}
        end
      end)

    case result do
      {:ok, {conn, user}} ->
        conn
        |> delete_session(:final_track_invite)
        |> delete_session(:final_track_invite_sso)
        |> put_flash(:info, "Welcome to Final Track!")
        |> UserAuth.log_in_user(user)

      {:error, :not_signed_in} ->
        conn
        |> put_flash(:error, "Sign in with NEIAM first, then accept the invite.")
        |> redirect(to: ~p"/users/register?#{[invite: token]}")

      error ->
        register_error(conn, error)
    end
  end

  defp local_register(conn, token, params) do
    case Accounts.register_by_invite(token, params) do
      {:ok, user} ->
        conn
        # A "Sign in with NEIAM" that was refused as not invited, earlier in
        # this browser, is linked to the new account (before log_in_user
        # renews the session and drops it).
        |> NeiamAuth.link_pending(user)
        |> put_flash(:info, "Welcome to Final Track!")
        |> UserAuth.log_in_user(user)

      {:error, %Ecto.Changeset{}} ->
        conn
        |> put_flash(
          :error,
          "Couldn't create the account: pick a password of at least 12 characters, typed the same twice."
        )
        |> redirect(to: ~p"/users/register?#{[invite: token]}")

      error ->
        register_error(conn, error)
    end
  end

  defp register_error(conn, {:error, :has_account}) do
    conn
    |> put_flash(:error, "That email already has an account. Log in instead.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp register_error(conn, {:error, _}) do
    conn
    |> put_flash(:error, "That invite link isn't valid any more.")
    |> redirect(to: ~p"/users/register")
  end
end
