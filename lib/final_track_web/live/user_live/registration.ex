defmodule FinalTrackWeb.UserLive.Registration do
  use FinalTrackWeb, :live_view

  alias FinalTrack.Accounts
  alias FinalTrack.Accounts.User

  # OIDC_LOGIN_MODE=sso_strict, an addressed invite: sign in with NEIAM
  # (InviteController.sso/2), then confirm (InviteController.register/2).
  @impl true
  def render(%{strict_invite?: true} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Accept your invite
            <:subtitle>
              For <span class="font-mono">{@invite.email}</span>. Final Track signs in with NEIAM.
            </:subtitle>
          </.header>
        </div>

        <div :if={!@sso_done?} id="invite-sso" class="mt-6 space-y-4">
          <p class="text-sm">First sign in with NEIAM; you'll come back here to finish.</p>
          <.link
            :for={p <- NeiamAuth.providers()}
            href={~p"/users/register/invite/sso?#{[invite: @invite_token, provider: p.id]}"}
            class="btn btn-primary w-full"
          >
            {p.label}
          </.link>
        </div>

        <.form
          :if={@sso_done?}
          for={%{}}
          id="invite_sso_registration_form"
          action={~p"/users/register/invite"}
          class="mt-6"
        >
          <input type="hidden" name="invite" value={@invite_token} />
          <.button class="btn btn-primary w-full">Create account and sign in</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <div :if={@gated} id="registration-gated" class="alert alert-warning mt-6">
          <.icon name="hero-lock-closed" class="size-5" />
          <div>
            <p class="font-semibold">Registration is invite-only right now.</p>
            <p class="text-sm">
              You'll need an invite link from an existing member to create an account.
            </p>
          </div>
        </div>

        <div
          :if={@invite && !@has_account?}
          id="registration-invited"
          class="alert alert-success mt-6"
        >
          <.icon name="hero-envelope-open" class="size-5" />
          <p>Welcome — your invite is valid. Finish creating your account below.</p>
        </div>

        <div
          :if={@has_account?}
          id="registration-has-account"
          class="mt-6 space-y-4 rounded-box border border-base-300 bg-base-200 p-6 text-sm"
        >
          <p>
            <span class="font-mono">{@invite.email}</span>
            already has an account, so there's nothing to register. Log in with it instead.
          </p>
          <.link id="invite-log-in" navigate={~p"/users/log-in"} class="btn btn-primary w-full">
            Log in
          </.link>
        </div>

        <.form
          :if={@addressed? && !@has_account?}
          for={@form}
          id="invite_registration_form"
          action={~p"/users/register/invite"}
          phx-submit="save_addressed"
          phx-change="validate_addressed"
          phx-trigger-action={@trigger_submit}
          class="mt-6"
        >
          <input type="hidden" name="invite" value={@invite_token} />
          <div class="fieldset mb-2">
            <span class="label mb-1">Email</span>
            <p
              id="invite-email"
              class="input w-full cursor-default select-all font-mono text-sm opacity-80"
            >
              {@invite.email}
            </p>
            <p class="mt-1 text-xs text-base-content/60">
              This invite is for this address, so it counts as confirmed.
            </p>
          </div>
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password_confirmation]}
            type="password"
            label="Password again"
            autocomplete="new-password"
            required
          />

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create account and sign in
          </.button>
        </.form>

        <%!-- With mail off, a password instead of an emailed confirmation;
             once valid, the form posts itself to the password log-in
             (phx-trigger-action), which signs the new account in. --%>
        <.form
          :if={!@gated && !@addressed?}
          for={@form}
          id="registration_form"
          action={~p"/users/log-in?_action=registered"}
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
        >
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <%= unless FinalTrack.Mailer.enabled?() do %>
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
              required
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label="Password again"
              autocomplete="new-password"
              required
            />
            <input type="hidden" name={@form[:remember_me].name} value="true" />
          <% end %>

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: FinalTrackWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(params, session, socket) do
    if NeiamAuth.local_login_enabled?(),
      do: local_mount(params, socket),
      else: sso_strict_mount(params, session, socket)
  end

  # OIDC_LOGIN_MODE=sso_strict: no local registration. Only an addressed
  # invite with no account yet stays, to be accepted through SSO.
  defp sso_strict_mount(params, session, socket) do
    token = params["invite"]
    invite = Accounts.get_active_invite(token)

    if invite && invite.email && !Accounts.get_user_by_email(invite.email) do
      {:ok,
       assign(socket,
         strict_invite?: true,
         invite: invite,
         invite_token: token,
         # Set by NeiamAuthAdapter.handle_error/2 when the SSO login for this
         # invite came back refused as not invited (and so is pending).
         sso_done?: session["final_track_invite_sso"] == token
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "Sign up by signing in with NEIAM.")
       |> redirect(to: ~p"/users/log-in")}
    end
  end

  defp local_mount(params, socket) do
    invite = Accounts.get_active_invite(params["invite"])
    gated = not Accounts.registration_open?() and is_nil(invite)
    # An invite addressed to an email registers that email only, confirmed
    # by the link; if it already has an account, they log in instead (a
    # link never signs anyone in to an existing account).
    addressed? = !!(invite && invite.email)
    has_account? = addressed? && !!Accounts.get_user_by_email(invite.email)

    socket =
      socket
      |> assign(:invite, invite)
      # The raw token from the link: only its hash is stored, so this is the
      # one copy there is to re-check and spend the invite with.
      |> assign(:invite_token, invite && params["invite"])
      |> assign(:gated, gated)
      |> assign(:addressed?, addressed?)
      |> assign(:has_account?, has_account?)
      |> assign(:trigger_submit, false)
      |> assign(:mail?, FinalTrack.Mailer.enabled?())

    if addressed?,
      do: {:ok, assign(socket, form: addressed_form(invite, %{}))},
      else:
        {:ok,
         assign_form(
           socket,
           Accounts.change_user_registration(%User{}, %{}, validate_unique: false)
         )}
  end

  @impl true
  def handle_event("validate_addressed", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: addressed_form(socket.assigns.invite, params, :validate))}
  end

  # Valid here: let the form post to InviteController.register, which
  # creates the account and sets the session.
  def handle_event("save_addressed", %{"user" => params}, socket) do
    form = addressed_form(socket.assigns.invite, params, :insert, validate_unique: true)

    if form.source.valid?,
      do: {:noreply, assign(socket, form: form, trigger_submit: true)},
      else: {:noreply, assign(socket, form: form)}
  end

  def handle_event("save", _params, %{assigns: %{gated: true}} = socket) do
    {:noreply, put_flash(socket, :error, "Registration is invite-only.")}
  end

  # An addressed invite registers only its own email, through the form above.
  def handle_event("save", _params, %{assigns: %{addressed?: true}} = socket) do
    {:noreply, put_flash(socket, :error, "This invite is for #{socket.assigns.invite.email}.")}
  end

  def handle_event("save", %{"user" => user_params}, socket) do
    case register(user_params, socket.assigns.invite_token) do
      # No mail to confirm by: the account is confirmed, and the form now
      # posts the same email and password to the log-in.
      {:ok, _user} when not socket.assigns.mail? ->
        {:noreply,
         socket
         |> assign_form(
           Accounts.change_user_registration(%User{}, user_params, validate_unique: false)
         )
         |> assign(:trigger_submit, true)}

      {:ok, user} ->
        # Not `{:ok, _} = ...`: the user (and any invite) is already
        # committed, so a failed send mustn't crash the page and strand them.
        {kind, message} =
          case Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}")) do
            {:ok, _} ->
              {:info,
               "An email was sent to #{user.email}, please access it to confirm your account."}

            {:error, _reason} ->
              {:error,
               "Your account was created, but we couldn't send the confirmation email. " <>
                 "Request a login link to try again."}
          end

        {:noreply,
         socket
         |> put_flash(kind, message)
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, :invite_used} ->
        {:noreply,
         socket
         |> assign(invite: nil, invite_token: nil, gated: not Accounts.registration_open?())
         |> put_flash(:error, "That invite has already been used.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset =
      %User{}
      |> Accounts.change_user_registration(user_params, validate_unique: false)
      |> then(fn cs ->
        if socket.assigns.mail?,
          do: cs,
          else: User.password_changeset(cs, user_params, hash_password: false)
      end)

    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # The invite is re-checked and spent in the same transaction as the user is
  # created, so one link can't be redeemed twice by two open tabs.
  defp register(user_params, nil), do: create_user(user_params)

  defp register(user_params, invite_token) do
    FinalTrack.Repo.transact(fn ->
      with %{} = invite <- Accounts.get_active_invite(invite_token) || {:error, :invite_used},
           {:ok, user} <- create_user(user_params),
           {:ok, _} <- Accounts.consume_invite(invite, user) do
        {:ok, user}
      end
    end)
  end

  # With mail, confirmed later by an emailed link; without, by a password now.
  defp create_user(user_params) do
    if FinalTrack.Mailer.enabled?(),
      do: Accounts.register_user(user_params),
      else: Accounts.register_confirmed_user(user_params)
  end

  defp addressed_form(invite, params, action \\ nil, opts \\ [validate_unique: false]) do
    params = Map.take(params, ["password", "password_confirmation"])
    attrs = Map.put(params, "email", invite.email)

    %User{}
    |> User.registration_changeset(attrs, opts)
    |> User.password_changeset(attrs, hash_password: false)
    |> Map.put(:action, action)
    |> to_form(as: "user")
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
