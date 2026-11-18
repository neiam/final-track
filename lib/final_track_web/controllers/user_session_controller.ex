defmodule FinalTrackWeb.UserSessionController do
  use FinalTrackWeb, :controller

  alias FinalTrack.Accounts
  alias FinalTrackWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  # Registered with a password, with mail off (UserLive.Registration).
  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created. Welcome to Final Track!")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    # Under OIDC_LOGIN_MODE=sso a linked account signs in through SSO only:
    # refuse before the token is spent.
    if NeiamAuth.password_login_allowed?(Accounts.get_user_by_magic_link_token(token)) do
      magic_link_log_in(conn, token, user_params, info)
    else
      sso_required(conn)
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params
    user = Accounts.get_user_by_email_and_password(email, password)

    cond do
      # Only after the password checked out, so this says nothing about an
      # address to someone who doesn't know its password.
      user && not reauth?(conn, user) && not NeiamAuth.password_login_allowed?(user) ->
        sso_required(conn)

      user ->
        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      true ->
        # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
        conn
        |> put_flash(:error, "Invalid email or password")
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # Re-auth of the signed-in user (sudo mode; update_password ends in
  # create/3) is not a sign-in.
  defp reauth?(conn, user) do
    case conn.assigns[:current_scope] do
      %{user: %{id: id}} -> id == user.id
      _ -> false
    end
  end

  defp sso_required(conn) do
    conn
    |> put_flash(:error, "This account signs in with NEIAM: use the Sign in with NEIAM button.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp magic_link_log_in(conn, token, user_params, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
