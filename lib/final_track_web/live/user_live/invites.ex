defmodule FinalTrackWeb.UserLive.Invites do
  @moduledoc """
  Your registration invites: make a link (optionally for one email address,
  which lets that person register from the link alone, confirmed), copy it,
  replace it, see who used it, revoke it.

  Only a hash of each link's token is stored, so a link can be shown once:
  when it is made or replaced ("New link"), in the `#shared-link` panel. The
  list shows the invites without links.
  """
  use FinalTrackWeb, :live_view

  alias FinalTrack.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user

    {:ok,
     socket
     |> assign(:page_title, "Invites")
     |> assign(:form, new_invite_form())
     |> assign(:shared_link, nil)
     |> stream(:invites, Accounts.list_invites(user))}
  end

  @impl true
  def handle_event("create_invite", params, socket) do
    attrs = %{email: get_in(params, ["invite", "email"])}

    case Accounts.create_invite(socket.assigns.current_scope.user, attrs) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> put_flash(:info, "Invite created. Copy the link below and hand it over.")
         |> assign(:form, new_invite_form())
         |> assign(:shared_link, shared_link(invite))
         |> stream_insert(:invites, FinalTrack.Repo.preload(invite, :consumed_by), at: 0)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: "invite"))}
    end
  end

  def handle_event("new_link", %{"id" => id}, socket) do
    case Accounts.rotate_invite(socket.assigns.current_scope.user, id) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> put_flash(:info, "New link made. The old one no longer works.")
         |> assign(:shared_link, shared_link(invite))
         |> stream_insert(:invites, invite)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not make a new link.")}
    end
  end

  def handle_event("revoke_invite", %{"id" => id}, socket) do
    case Accounts.revoke_invite(socket.assigns.current_scope.user, id) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> update(:shared_link, &if(&1 && &1.id == invite.id, do: nil, else: &1))
         |> stream_insert(:invites, invite)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not revoke invite.")}
    end
  end

  def handle_event("dismiss_link", _params, socket),
    do: {:noreply, assign(socket, :shared_link, nil)}

  defp new_invite_form, do: to_form(%{"email" => ""}, as: "invite")

  # The raw token is on the invite only as it comes back from create or
  # rotate, so this is the one chance to show its link.
  defp shared_link(invite),
    do: %{id: invite.id, email: invite.email, url: FinalTrackWeb.invite_url(invite)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <header class="flex items-center justify-between gap-4 mb-4">
        <div>
          <h1 class="text-2xl font-bold">Invites</h1>
          <p class="text-sm text-base-content/70">
            Each invite link can be used once to create a new account. Nothing is emailed: copy
            the link and hand it over yourself.
          </p>
        </div>
      </header>

      <.form
        for={@form}
        id="invite-form"
        phx-submit="create_invite"
        class="mb-2 flex flex-col gap-2 rounded-box border border-base-300 bg-base-200 p-3 sm:flex-row sm:items-start"
      >
        <div class="flex-1">
          <.input
            field={@form[:email]}
            type="email"
            placeholder="Their email (optional)"
            autocomplete="off"
            spellcheck="false"
          />
        </div>
        <button
          type="submit"
          id="btn-create-invite"
          class="btn btn-primary sm:mt-1"
          phx-disable-with="Creating…"
        >
          <.icon name="hero-plus-micro" class="size-4" /> New invite
        </button>
      </.form>
      <p class="mb-6 text-xs text-base-content/60">
        With an email, the link is for that person only: they pick a password and are
        signed in straight away, their address counted as confirmed. If it already has an account,
        the link just sends them to log in. Without one, anyone holding the link can register once.
      </p>

      <div
        :if={@shared_link}
        id="shared-link"
        class="mb-6 space-y-2 rounded-box border border-primary/40 bg-base-100 p-3 motion-safe:animate-[fade-in_150ms_ease-out]"
      >
        <p class="text-sm">
          <%= if @shared_link.email do %>
            Invite link for <span class="font-mono">{@shared_link.email}</span>.
          <% else %>
            Invite link. Anyone holding it can register once.
          <% end %>
        </p>
        <div class="flex gap-2">
          <input
            id="shared-link-url"
            type="text"
            readonly
            value={@shared_link.url}
            class="input input-sm min-w-0 flex-1 font-mono text-xs"
          />
          <button
            id="copy-shared-link"
            type="button"
            phx-hook=".CopyLink"
            data-target="shared-link-url"
            class="btn btn-primary btn-sm transition"
            title="Copy link"
          >
            <.icon name="hero-clipboard-document-micro" class="size-4" />
            <span data-label>Copy</span>
          </button>
        </div>
        <p class="text-xs text-base-content/60">
          Shown once: only a fingerprint of it is kept. Lost it? "New link" on the invite makes
          another and stops this one working.
        </p>
        <button
          id="dismiss-shared-link"
          type="button"
          class="btn btn-ghost btn-xs"
          phx-click="dismiss_link"
        >
          Done
        </button>
      </div>

      <ul id="invites" phx-update="stream" class="flex flex-col gap-2">
        <li id="invites-empty" class="hidden only:block text-center text-sm opacity-60 py-8">
          No invites yet. Click <em class="not-italic font-semibold">New invite</em> to create one.
        </li>
        <li
          :for={{dom_id, invite} <- @streams.invites}
          id={dom_id}
          class={[
            "border border-base-300 rounded-box p-3 flex items-center gap-3 bg-base-200 transition",
            invite.consumed_at && "opacity-60"
          ]}
        >
          <div class="flex-1 min-w-0">
            <div class="flex items-center gap-2 text-xs">
              <span :if={invite.consumed_at && invite.consumed_by_id} class="badge badge-ghost">
                used
              </span>
              <span
                :if={invite.consumed_at && is_nil(invite.consumed_by_id)}
                class="badge badge-error"
              >
                revoked
              </span>
              <span :if={is_nil(invite.consumed_at)} class="badge badge-success">active</span>
              <span :if={invite.expires_at} class="opacity-60">
                expires {Calendar.strftime(invite.expires_at, "%Y-%m-%d")}
              </span>
              <span :if={invite.note} class="opacity-70 truncate">{invite.note}</span>
            </div>
            <p :if={invite.email} class="mt-1 truncate text-sm">
              For <span class="font-mono">{invite.email}</span>
            </p>
            <div :if={is_nil(invite.consumed_at)} class="mt-1 flex items-center gap-2">
              <button
                type="button"
                id={"new-link-#{dom_id}"}
                phx-click="new_link"
                phx-value-id={invite.id}
                data-confirm="Make a new link? The current one will stop working."
                class="btn btn-ghost btn-xs"
                title="Replace the link; the old one stops working"
              >
                <.icon name="hero-arrow-path-micro" class="size-4" /> New link
              </button>
            </div>
            <p :if={invite.consumed_by} class="text-xs opacity-70 mt-1">
              Redeemed by <span class="font-mono">{invite.consumed_by.email}</span>
              on {Calendar.strftime(invite.consumed_at, "%Y-%m-%d %H:%M")}
            </p>
          </div>
          <button
            :if={is_nil(invite.consumed_at)}
            type="button"
            id={"revoke-#{dom_id}"}
            phx-click="revoke_invite"
            phx-value-id={invite.id}
            class="btn btn-ghost btn-xs text-error"
            title="Revoke invite"
          >
            <.icon name="hero-x-mark-micro" class="size-4" />
          </button>
        </li>
      </ul>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyLink">
        export default {
          mounted() {
            this.el.addEventListener("click", async () => {
              const input = document.getElementById(this.el.dataset.target)
              const label = this.el.querySelector("[data-label]")
              try {
                await navigator.clipboard.writeText(input.value)
              } catch (_e) {
                // Plain http (a LAN server) has no clipboard API: select it instead.
                input.select()
                document.execCommand("copy")
              }
              if (label) {
                label.textContent = "Copied"
                setTimeout(() => { label.textContent = "Copy" }, 1500)
              }
            })
          }
        }
      </script>
    </Layouts.app>
    """
  end
end
