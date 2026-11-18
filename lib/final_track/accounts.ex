defmodule FinalTrack.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias FinalTrack.Repo

  alias FinalTrack.Accounts.{Invite, User, UserToken, UserNotifier}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates an account with a password and its email already confirmed: for
  someone arriving by an invite addressed to them, which proves the address
  as an emailed link would. Takes `email`, `password` and
  `password_confirmation`. With `password: false`, no password is taken and
  the account has none (it signs in through SSO only).
  """
  def register_confirmed_user(attrs, opts \\ []) do
    %User{}
    |> User.registration_changeset(attrs)
    |> then(fn changeset ->
      if Keyword.get(opts, :password, true),
        do: User.password_changeset(changeset, attrs),
        else: changeset
    end)
    |> User.confirm_changeset()
    |> Repo.insert()
  end

  @doc "A changeset for the registration form."
  def change_user_registration(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.registration_changeset(user, attrs, opts)
  end

  ## Invites

  @doc """
  Returns true when public registration is open. When false (the default),
  registration requires a valid invite token.
  """
  @spec registration_open?() :: boolean()
  def registration_open? do
    Application.get_env(:final_track, :registration_open, false) == true
  end

  @doc """
  Creates an invite, owned by `owner` — or by nobody when `owner` is nil,
  which is what the very first invite (from the command line) looks like.

  `attrs` may carry `:note`, `:email` (to address it to one person; see
  `FinalTrack.Accounts.Invite`) and `:expires_at`, or `:days` to expire that
  many days from now.

  The returned invite carries its raw link `token`, the only time it exists:
  only its hash is stored.
  """
  def create_invite(owner, attrs \\ %{}) do
    attrs = Map.new(attrs)

    expires_at =
      case attrs[:days] do
        days when is_integer(days) and days > 0 ->
          DateTime.utc_now() |> DateTime.add(days, :day) |> DateTime.truncate(:second)

        _ ->
          attrs[:expires_at]
      end

    attrs =
      attrs
      |> Map.take([:note, :email])
      |> Map.put(:expires_at, expires_at)
      |> Map.put(:created_by_id, owner && owner.id)

    %Invite{}
    |> Invite.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The command-line way in, shared by `mix final_track.invite` and the release's
  `bin/invite`: `opts` are `:email` (whom it is for), `:note`, `:days` and
  `:by` (an owner's email).
  """
  def create_invite_from_cli(opts) do
    owner =
      case opts[:by] do
        nil ->
          {:ok, nil}

        email ->
          if user = get_user_by_email(email), do: {:ok, user}, else: {:error, :no_such_user}
      end

    with {:ok, owner} <- owner do
      create_invite(owner, Map.take(Map.new(opts), [:email, :note, :days]))
    end
  end

  @doc "Lists invites created by a user, newest first, with redeemer preloaded."
  def list_invites(%User{id: id}) do
    from(i in Invite,
      where: i.created_by_id == ^id,
      order_by: [desc: i.inserted_at],
      preload: [:consumed_by]
    )
    |> Repo.all()
  end

  @doc "Looks up an invite by the raw token from its link and returns it if active."
  def get_active_invite(token) when is_binary(token) do
    case Repo.get_by(Invite, token_hash: Invite.hash_token(token)) do
      nil -> nil
      invite -> if Invite.active?(invite), do: invite, else: nil
    end
  end

  def get_active_invite(_), do: nil

  @doc "Marks an invite as consumed by the given user."
  def consume_invite(%Invite{} = invite, %User{} = user) do
    invite
    |> Invite.consume_changeset(user)
    |> Repo.update()
  end

  @doc """
  Gives one of `owner`'s active invites a new token and returns it, so any
  earlier copy of the link stops working. The returned invite carries the
  new raw `token`, to show once. Anyone else's, or a spent one, is
  `{:error, :not_found}`.
  """
  def rotate_invite(%User{id: owner_id}, invite_id) do
    with {:ok, invite_id} <- Ecto.UUID.cast(invite_id),
         %Invite{} = invite <- Repo.get_by(Invite, id: invite_id, created_by_id: owner_id),
         true <- Invite.active?(invite) do
      invite
      |> Invite.rotate_token_changeset()
      |> Repo.update()
      |> case do
        {:ok, invite} -> {:ok, Repo.preload(invite, :consumed_by)}
        error -> error
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The command-line way to a fresh link for the newest active invite
  addressed to `email` (whoever owns it): rotates its token, so earlier
  links stop working. `{:error, :not_found}` when there is none.
  """
  def rotate_invite_for_email(email) when is_binary(email) do
    from(i in Invite,
      where: i.email == ^String.trim(email) and is_nil(i.consumed_at),
      order_by: [desc: i.inserted_at]
    )
    |> Repo.all()
    |> Enum.find(&Invite.active?/1)
    |> case do
      nil -> {:error, :not_found}
      invite -> invite |> Invite.rotate_token_changeset() |> Repo.update()
    end
  end

  @doc """
  Registers from an invite addressed to an email, with no account yet:
  creates the account for that email (confirmed, with the given password) and spends the invite, in one transaction. Returns
  `{:ok, user}`; the caller signs them in.

  Refuses with `{:error, :has_account}` when the email already has an
  account: an invite link must never sign anyone in to an existing account,
  or addressing an invite to someone would hand over their account.
  `{:error, :invalid}` for a spent, expired or unaddressed invite.

  `opts` go to `register_confirmed_user/2`: `password: false` registers
  without a password (`OIDC_LOGIN_MODE=sso_strict`).
  """
  def register_by_invite(token, attrs, opts \\ [])

  def register_by_invite(token, attrs, opts) when is_binary(token) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    Repo.transact(fn ->
      # Locked, so two submits of one link can't both spend it.
      invite =
        Repo.one(
          from(i in Invite,
            where: i.token_hash == ^Invite.hash_token(token),
            lock: "FOR UPDATE"
          )
        )

      cond do
        is_nil(invite) or not Invite.active?(invite) or is_nil(invite.email) ->
          {:error, :invalid}

        get_user_by_email(invite.email) ->
          {:error, :has_account}

        true ->
          with {:ok, user} <-
                 register_confirmed_user(
                   attrs
                   |> Map.take(["password", "password_confirmation"])
                   |> Map.put("email", invite.email),
                   opts
                 ),
               {:ok, _} <- consume_invite(invite, user) do
            {:ok, user}
          end
      end
    end)
  end

  def register_by_invite(_, _, _), do: {:error, :invalid}

  @doc "Revokes one of `owner`'s invites by id. Anyone else's, or a missing one, is `{:error, :not_found}`."
  def revoke_invite(%User{id: owner_id}, invite_id) do
    with {:ok, invite_id} <- Ecto.UUID.cast(invite_id),
         %Invite{consumed_at: nil} = invite <-
           Repo.get_by(Invite, id: invite_id, created_by_id: owner_id) do
      invite
      |> Ecto.Changeset.change(consumed_at: DateTime.utc_now(:second), consumed_by_id: nil)
      |> Repo.update()
      |> case do
        {:ok, invite} -> {:ok, Repo.preload(invite, :consumed_by)}
        error -> error
      end
    else
      _ -> {:error, :not_found}
    end
  end

  ## Admins

  @doc """
  Makes `user` an admin, or not. Only ever called from trusted code (the
  OIDC adapter for the admin group, the release command); never from a
  form, and `is_admin` is in no changeset's cast.
  """
  def set_admin(%User{} = user, admin?) when is_boolean(admin?) do
    user |> Ecto.Changeset.change(is_admin: admin?) |> Repo.update()
  end

  @doc "Whether `user` is an admin."
  def admin?(%User{is_admin: true}), do: true
  def admin?(_), do: false

  ## Profile

  @doc "A changeset for the profile form."
  def change_user_profile(%User{} = user, attrs \\ %{}, opts \\ []) do
    User.profile_changeset(user, attrs, opts)
  end

  @doc "Updates the user's display name."
  def update_user_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `FinalTrack.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `FinalTrack.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
