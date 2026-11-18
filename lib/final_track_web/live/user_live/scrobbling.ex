defmodule FinalTrackWeb.UserLive.Scrobbling do
  @moduledoc """
  Your scrobbling clients: mint a token per device (shown once), see when
  each was last used, revoke one. Explains how to point Scropple, or
  anything that speaks its HTTP backend's JSON, at this server.
  """
  use FinalTrackWeb, :live_view

  alias FinalTrack.{Federation, Privacy, Scrobbles}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Scrobbling")
     |> assign(:base_url, FinalTrackWeb.base_url())
     |> assign(:new_token, nil)
     |> assign(:form, new_form())
     |> load_tokens()
     |> load_marks()
     |> load_fediverse()}
  end

  defp load_marks(socket),
    do: assign(socket, :marks, Privacy.list_marks(socket.assigns.current_scope.user))

  defp new_form, do: to_form(%{"label" => ""}, as: :token)

  defp load_tokens(socket) do
    tokens = Scrobbles.list_tokens(socket.assigns.current_scope.user)

    socket
    |> assign(:tokens_empty?, tokens == [])
    |> stream(:tokens, tokens, reset: true)
  end

  @impl true
  def handle_event("create_token", %{"token" => params}, socket) do
    case Scrobbles.create_token(socket.assigns.current_scope.user, params) do
      {:ok, plaintext, token} ->
        {:noreply,
         socket
         |> assign(:new_token, %{id: token.id, value: plaintext, label: token.label})
         |> assign(:form, new_form())
         |> load_tokens()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :token))}
    end
  end

  def handle_event("revoke_token", %{"id" => id}, socket) do
    socket =
      case Scrobbles.revoke_token(socket.assigns.current_scope.user, id) do
        :ok ->
          socket
          |> update(:new_token, &if(&1 && &1.id == id, do: nil, else: &1))
          |> put_flash(:info, "Token revoked. That client can no longer scrobble.")

        {:error, :not_found} ->
          put_flash(socket, :error, "That token was already gone.")
      end

    {:noreply, load_tokens(socket)}
  end

  def handle_event("dismiss_token", _params, socket),
    do: {:noreply, assign(socket, :new_token, nil)}

  def handle_event("validate_fediverse", %{"fediverse" => params}, socket) do
    changeset =
      socket.assigns.current_scope.user
      |> Federation.change_account(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :fediverse_form, to_form(changeset, as: :fediverse))}
  end

  def handle_event("save_fediverse", %{"fediverse" => params}, socket) do
    case Federation.save_account(socket.assigns.current_scope.user, params) do
      {:ok, account} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           if(account.enabled, do: "Posting to the fediverse.", else: "Fediverse settings saved.")
         )
         |> load_fediverse()}

      {:error, changeset} ->
        {:noreply, assign(socket, :fediverse_form, to_form(changeset, as: :fediverse))}
    end
  end

  def handle_event("unmark", %{"id" => id}, socket) do
    _ = Privacy.delete_mark(socket.assigns.current_scope.user, id)
    {:noreply, socket |> load_marks() |> put_flash(:info, "Shared again.")}
  end

  defp load_fediverse(socket) do
    if Federation.enabled?() do
      user = socket.assigns.current_scope.user
      account = Federation.get_account(user)

      socket
      |> assign(:fediverse?, true)
      |> assign(:fediverse_account, account)
      |> assign(:fediverse_form, to_form(Federation.change_account(user), as: :fediverse))
      |> assign(:fediverse_domain, FinalTrack.Federation.Objects.domain())
      |> assign(:fediverse_followers, account && Federation.follower_count(account))
      |> assign(:fediverse_posts, account && Federation.post_count(account))
    else
      assign(socket, :fediverse?, false)
    end
  end

  defp mark_kind(%{artist: %{}}), do: "artist"
  defp mark_kind(%{album: %{}}), do: "album"
  defp mark_kind(%{track: %{}}), do: "track"

  defp mark_name(%{artist: %{name: name}}), do: name
  defp mark_name(%{album: %{title: title, artist: artist}}), do: "#{title} · #{artist.name}"
  defp mark_name(%{track: %{title: title, artist: artist}}), do: "#{title} · #{artist.name}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-3xl space-y-8">
        <header>
          <p class="font-mono text-xs uppercase tracking-[0.25em] text-accent">Scrobbling</p>
          <h1 class="mt-1 text-3xl font-bold tracking-tight">Your clients</h1>
          <p class="mt-2 text-base-content/70">
            Each device that scrobbles gets its own token. Revoke one and that device stops
            scrobbling on its next request; the others carry on.
          </p>
        </header>

        <.form
          for={@form}
          id="token-form"
          phx-submit="create_token"
          class="flex flex-col gap-2 rounded-box border border-base-300 bg-base-200 p-3 sm:flex-row sm:items-start"
        >
          <div class="flex-1">
            <.input
              field={@form[:label]}
              type="text"
              placeholder="Device name, e.g. Pixel 8 (optional)"
              maxlength="80"
              autocomplete="off"
            />
          </div>
          <button
            id="create-token"
            type="submit"
            class="btn btn-primary sm:mt-1"
            phx-disable-with="Creating…"
          >
            <.icon name="hero-key-micro" class="size-4" /> New token
          </button>
        </.form>

        <div
          :if={@new_token}
          id="new-token"
          class="space-y-3 rounded-box border border-primary/40 bg-base-100 p-4 motion-safe:animate-[fade-in_150ms_ease-out]"
        >
          <p class="text-sm font-medium">
            Token{if @new_token.label, do: " for #{@new_token.label}"}. Copy it now: it's shown
            once, and only a fingerprint of it is kept.
          </p>
          <div class="flex gap-2">
            <input
              id="new-token-value"
              type="text"
              readonly
              value={@new_token.value}
              class="input input-sm min-w-0 flex-1 font-mono text-xs"
            />
            <button
              id="copy-token"
              type="button"
              phx-hook=".CopyValue"
              data-target="new-token-value"
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-clipboard-document-micro" class="size-4" />
              <span data-label>Copy</span>
            </button>
          </div>
          <button
            id="dismiss-token"
            type="button"
            phx-click="dismiss_token"
            class="btn btn-ghost btn-xs"
          >
            Done
          </button>
        </div>

        <section>
          <h2 class="mb-2 font-semibold">Tokens</h2>
          <ul
            id="tokens"
            phx-update="stream"
            class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-200"
          >
            <li
              id="tokens-empty"
              class="hidden only:block p-6 text-center text-sm text-base-content/60"
            >
              No tokens yet. Make one above for each device you scrobble from.
            </li>
            <li
              :for={{dom_id, token} <- @streams.tokens}
              id={dom_id}
              class="group flex items-center gap-3 px-4 py-3"
            >
              <.icon name="hero-device-phone-mobile" class="size-5 shrink-0 text-base-content/60" />
              <div class="min-w-0 flex-1">
                <p class="truncate font-medium">{token.label || "Unnamed client"}</p>
                <p class="text-xs text-base-content/60">
                  Created {Calendar.strftime(token.inserted_at, "%-d %b %Y")} · {if token.last_used_at,
                    do: "last used #{ago(token.last_used_at)}",
                    else: "never used"}
                </p>
              </div>
              <button
                id={"revoke-#{dom_id}"}
                type="button"
                phx-click="revoke_token"
                phx-value-id={token.id}
                data-confirm="Revoke this token? That client stops scrobbling."
                class="btn btn-ghost btn-sm text-error opacity-70 transition group-hover:opacity-100"
              >
                Revoke
              </button>
            </li>
          </ul>
        </section>

        <section
          :if={@fediverse?}
          id="fediverse"
          class="space-y-4 rounded-box border border-base-300 bg-base-200 p-5"
        >
          <div>
            <h2 class="flex items-center gap-2 font-semibold">
              <.icon name="hero-globe-alt-micro" class="size-4 text-accent" /> Fediverse
            </h2>
            <p class="mt-1 text-sm text-base-content/70">
              Give your plays an account that Mastodon, Pixelfed and other fediverse users can
              follow. While it's on, every play you scrobble is posted with its album cover. Private
              plays never are, and marking something private withdraws what was already posted.
            </p>
          </div>

          <div
            :if={@fediverse_account}
            id="fediverse-status"
            class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm"
          >
            <span class="font-mono select-all">
              @{@fediverse_account.username}@{@fediverse_domain}
            </span>
            <span class={[
              "badge badge-sm",
              if(@fediverse_account.enabled, do: "badge-success", else: "badge-ghost")
            ]}>
              {if @fediverse_account.enabled, do: "posting", else: "off"}
            </span>
            <span
              :if={@fediverse_account.enabled}
              id="fediverse-visibility"
              class="badge badge-sm badge-ghost"
            >
              {if @fediverse_account.visibility == "public", do: "public", else: "followers only"}
            </span>
            <span class="text-base-content/60">
              {@fediverse_followers} {if @fediverse_followers == 1, do: "follower", else: "followers"} · {@fediverse_posts} {if @fediverse_posts ==
                                                                                                                                  1,
                                                                                                                                do:
                                                                                                                                  "post",
                                                                                                                                else:
                                                                                                                                  "posts"}
            </span>
          </div>

          <.form
            for={@fediverse_form}
            id="fediverse-form"
            phx-change="validate_fediverse"
            phx-submit="save_fediverse"
            class="space-y-3"
          >
            <div class="flex flex-col gap-3 sm:flex-row sm:items-end">
              <div class="flex-1">
                <.input
                  field={@fediverse_form[:username]}
                  type="text"
                  label="Username"
                  placeholder="e.g. alice"
                  autocomplete="off"
                  spellcheck="false"
                />
              </div>
              <div class="sm:flex-1">
                <.input
                  field={@fediverse_form[:visibility]}
                  type="select"
                  label="Who sees the posts"
                  options={
                    Enum.map(FinalTrack.Federation.Account.visibilities(), fn {v, l} -> {l, v} end)
                  }
                />
              </div>
            </div>
            <p class="-mt-1 text-xs text-base-content/60">
              Followers' feeds only keeps a post-per-play out of public timelines, but Pixelfed and
              angler then don't show the posts on your profile page. Public shows them everywhere.
              Changing it applies to new posts.
            </p>
            <div class="sm:w-1/2">
              <.input
                field={@fediverse_form[:hashtag]}
                type="text"
                label="Hashtag"
                placeholder="none"
                autocomplete="off"
                spellcheck="false"
              />
              <p class="-mt-1 text-xs text-base-content/60">
                Added to every post<span :if={@fediverse_form[:hashtag].value not in [nil, ""]}>
                  as <span class="font-mono">#{String.trim_leading(to_string(@fediverse_form[:hashtag].value), "#")}</span></span>, so anyone who'd rather not see a post per play can filter or mute the tag
                instead of unfollowing. Leave it empty for none.
              </p>
            </div>
            <div class="flex items-center justify-between gap-3">
              <.input field={@fediverse_form[:enabled]} type="checkbox" label="Post my plays" />
              <button
                id="save-fediverse"
                type="submit"
                class="btn btn-primary"
                phx-disable-with="Saving…"
              >
                Save
              </button>
            </div>
          </.form>
        </section>

        <section id="private-marks">
          <h2 class="mb-1 flex items-center gap-2 font-semibold">
            <.icon name="hero-lock-closed-micro" class="size-4 text-warning" /> Kept private
          </h2>
          <p class="mb-2 text-sm text-base-content/70">
            Your plays of these are only shown to you: they're left out of everyone else's charts,
            "Listening now" and "Latest plays". Mark more from any artist or album page.
          </p>
          <p
            :if={@marks == []}
            id="no-private-marks"
            class="rounded-box border border-dashed border-base-300 p-4 text-center text-sm text-base-content/60"
          >
            Nothing kept private.
          </p>
          <ul
            :if={@marks != []}
            class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-200"
          >
            <li :for={mark <- @marks} id={"mark-#{mark.id}"} class="flex items-center gap-3 px-4 py-2">
              <span class="badge badge-ghost badge-sm w-14 justify-center">{mark_kind(mark)}</span>
              <span class="min-w-0 flex-1 truncate text-sm">{mark_name(mark)}</span>
              <button
                id={"unmark-#{mark.id}"}
                type="button"
                phx-click="unmark"
                phx-value-id={mark.id}
                class="btn btn-ghost btn-xs"
              >
                Share again
              </button>
            </li>
          </ul>
        </section>

        <section
          id="setup"
          class="space-y-4 rounded-box border border-base-300 bg-base-200 p-5 text-sm"
        >
          <h2 class="flex items-center gap-2 font-semibold">
            <.icon name="hero-wrench-screwdriver-micro" class="size-4 text-accent" />
            Setting up Scropple
          </h2>
          <ol class="list-decimal space-y-1 pl-5 text-base-content/80">
            <li>
              In Scropple, open <strong>Backends</strong>
              → <strong>Add</strong>
              → <strong>HTTP</strong>.
            </li>
            <li>
              Base URL: <code id="setup-base-url" class="font-mono select-all">{@base_url}</code>
            </li>
            <li>Token: the one you made above.</li>
          </ol>
          <p class="text-base-content/70">
            Scropple keeps sending to its other backends (Last.fm, ListenBrainz, an ircd channel)
            too. Anything that speaks the same JSON works; for example:
          </p>
          <pre
            class="overflow-x-auto rounded-field bg-base-300 p-3 font-mono text-xs leading-relaxed"
            phx-no-curly-interpolation
          ><code>curl -X POST <%= @base_url %>/api/v1/scrobble \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d '[{"artist": "Pink Floyd", "track": "Time",
            "album": "The Dark Side of the Moon",
            "durationSec": 413, "timestamp": 1763494445}]'</code></pre>
          <p class="text-base-content/70">
            <code class="font-mono">POST /api/v1/now-playing</code>
            takes one such object and shows it under "Listening now".
          </p>
        </section>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyValue">
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
