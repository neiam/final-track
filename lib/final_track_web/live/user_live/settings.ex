defmodule FinalTrackWeb.UserLive.Settings do
  use FinalTrackWeb, :live_view

  on_mount {FinalTrackWeb.UserAuth, :require_sudo_mode}

  alias FinalTrack.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="text-center">
        <.header>
          Account Settings
          <:subtitle>Your profile, email and password</:subtitle>
        </.header>
      </div>

      <.form
        for={@profile_form}
        id="profile_form"
        phx-submit="update_profile"
        phx-change="validate_profile"
      >
        <.input field={@profile_form[:display_name]} type="text" label="Display name" />
        <.button variant="primary" phx-disable-with="Saving...">Save Profile</.button>
      </.form>

      <div class="divider" />

      <p
        :if={!FinalTrack.Mailer.enabled?()}
        id="email-change-unavailable"
        class="text-sm text-base-content/70"
      >
        Signed in as <span class="font-mono">{@current_email}</span>. Changing it needs a
        confirmation email, and this server doesn't send mail.
      </p>

      <.form
        :if={FinalTrack.Mailer.enabled?()}
        for={@email_form}
        id="email_form"
        phx-submit="update_email"
        phx-change="validate_email"
      >
        <.input
          field={@email_form[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          required
        />
        <.button variant="primary" phx-disable-with="Changing...">Change Email</.button>
      </.form>

      <div class="divider" />

      <.form
        for={@password_form}
        id="password_form"
        action={~p"/users/update-password"}
        method="post"
        phx-change="validate_password"
        phx-submit="update_password"
        phx-trigger-action={@trigger_submit}
      >
        <input
          name={@password_form[:email].name}
          type="hidden"
          id="hidden_user_email"
          spellcheck="false"
          value={@current_email}
        />
        <.input
          field={@password_form[:password]}
          type="password"
          label="New password"
          autocomplete="new-password"
          spellcheck="false"
          required
        />
        <.input
          field={@password_form[:password_confirmation]}
          type="password"
          label="Confirm new password"
          autocomplete="new-password"
          spellcheck="false"
        />
        <.button variant="primary" phx-disable-with="Saving...">
          Save Password
        </.button>
      </.form>

      <%!-- Link this account to an SSO provider; nothing while OIDC_ENABLED is off. --%>
      <div :if={NeiamAuth.providers() != []} id="neiam_auth_settings" class="space-y-2">
        <div class="divider" />
        <NeiamAuth.Components.neiam_link_buttons user={@current_scope.user} class="btn w-full" />
        <NeiamAuth.Components.neiam_global_logout user={@current_scope.user} class="link text-sm" />
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, "Email changed successfully.")

        {:error, _} ->
          put_flash(socket, :error, "Email change link is invalid or it has expired.")
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:profile_form, profile_form(Accounts.change_user_profile(user)))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  defp profile_form(changeset), do: to_form(changeset, as: :profile)

  @impl true
  def handle_event("validate_profile", %{"profile" => params}, socket) do
    form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_profile(params)
      |> Map.put(:action, :validate)
      |> profile_form()

    {:noreply, assign(socket, :profile_form, form)}
  end

  def handle_event("update_profile", %{"profile" => params}, socket) do
    case Accounts.update_user_profile(socket.assigns.current_scope.user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, "Profile updated.")
         |> assign(:profile_form, profile_form(Accounts.change_user_profile(user)))}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, profile_form(changeset))}
    end
  end

  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = "A link to confirm your email change has been sent to the new address."
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
