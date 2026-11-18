defmodule FinalTrackWeb.UserLive.Login do
  use FinalTrackWeb, :live_view

  alias FinalTrack.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm space-y-4">
        <div class="text-center">
          <.header>
            <p>Log in</p>
            <:subtitle>
              <%= cond do %>
                <% @current_scope -> %>
                  You need to reauthenticate to perform sensitive actions on your account.
                <% not NeiamAuth.local_login_enabled?() -> %>
                  New here? Ask a member for an invite.
                <% true -> %>
                  Don't have an account? <.link
                    navigate={~p"/users/register"}
                    class="font-semibold text-brand hover:underline"
                    phx-no-format
                  >Sign up</.link> for an account now.
              <% end %>
            </:subtitle>
          </.header>
        </div>

        <div :if={local_mail_adapter?() and NeiamAuth.local_login_enabled?()} class="alert alert-info">
          <.icon name="hero-information-circle" class="size-6 shrink-0" />
          <div>
            <p>You are running the local mail adapter.</p>
            <p>
              To see sent emails, visit <.link href="/dev/mailbox" class="underline">the mailbox page</.link>.
            </p>
          </div>
        </div>

        <%!-- One button per configured provider; nothing while OIDC_ENABLED is
             off. Plain links: the browser has to leave LiveView for the IdP.
             This page is on the app host only, like /auth/oidc/*. --%>
        <div :if={NeiamAuth.enabled?() and NeiamAuth.providers() != []} class="space-y-4">
          <NeiamAuth.Components.neiam_sign_in_buttons class="btn btn-primary w-full" />
          <div :if={NeiamAuth.local_login_enabled?()} class="divider">or</div>
        </div>

        <%!-- OIDC_LOGIN_MODE=sso_strict: SSO is the only way in, so neither
             local form is shown (and UserSessionController refuses both). --%>
        <%= if NeiamAuth.local_login_enabled?() do %>
          <%!-- An emailed link only while this server sends mail. --%>
          <.form
            :let={f}
            :if={FinalTrack.Mailer.enabled?()}
            for={@form}
            id="login_form_magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button class="btn btn-primary w-full">
              Log in with email <span aria-hidden="true">→</span>
            </.button>
          </.form>

          <div :if={FinalTrack.Mailer.enabled?()} class="divider">or</div>

          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              spellcheck="false"
            />
            <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
              Log in and stay logged in <span aria-hidden="true">→</span>
            </.button>
            <.button class="btn btn-primary btn-soft w-full mt-2">
              Log in only this time
            </.button>
          </.form>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if FinalTrack.Mailer.enabled?(),
      do: submit_magic(email, socket),
      else:
        {:noreply,
         put_flash(socket, :error, "This server doesn't send mail: log in with your password.")}
  end

  defp submit_magic(email, socket) do
    # No link for an account that must sign in through SSO
    # (OIDC_LOGIN_MODE=sso, linked), and the same flash either way.
    if (user = Accounts.get_user_by_email(email)) && NeiamAuth.password_login_allowed?(user) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:final_track, FinalTrack.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
