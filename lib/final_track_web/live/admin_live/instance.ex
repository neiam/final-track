defmodule FinalTrackWeb.AdminLive.Instance do
  @moduledoc """
  `/admin/instance`: what the server calls itself — the node name and
  description NodeInfo reports and the instance's fediverse actor carries.
  Admins only. A blank field falls back to the environment's value
  (`FINAL_TRACK_NODE_NAME` / `_DESCRIPTION`), then the default; each field
  shows what that would be.
  """
  use FinalTrackWeb, :live_view

  on_mount {FinalTrackWeb.UserAuth, :require_admin}

  alias FinalTrack.Instance

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Instance")
     |> assign(:defaults, Instance.defaults())
     |> assign(:form, to_form(Instance.change_settings(), as: :instance))}
  end

  @impl true
  def handle_event("validate", %{"instance" => params}, socket) do
    form =
      params
      |> Instance.change_settings()
      |> Map.put(:action, :validate)
      |> to_form(as: :instance)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"instance" => params}, socket) do
    case Instance.update_settings(params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved. NodeInfo reports it from now on.")
         |> assign(:form, to_form(Instance.change_settings(), as: :instance))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :instance))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl space-y-6">
        <header>
          <p class="font-mono text-xs uppercase tracking-[0.25em] text-accent">Admin</p>
          <h1 class="mt-1 text-3xl font-bold tracking-tight">Instance</h1>
          <p class="mt-2 text-base-content/70">
            What this server calls itself in
            <a href={~p"/nodeinfo/2.1"} class="link" target="_blank" rel="noopener">NodeInfo</a>
            and on its own fediverse account: what directories and other servers show for it.
          </p>
        </header>

        <.form
          for={@form}
          id="instance-form"
          phx-change="validate"
          phx-submit="save"
          class="space-y-4 rounded-box border border-base-300 bg-base-200 p-5"
        >
          <div>
            <.input
              field={@form[:node_name]}
              type="text"
              label="Name"
              placeholder={@defaults.node_name}
            />
            <p class="-mt-1 text-xs text-base-content/60">
              Empty uses <span class="font-medium">{@defaults.node_name}</span>.
            </p>
          </div>
          <div>
            <.input
              field={@form[:node_description]}
              type="textarea"
              label="Description"
              placeholder={@defaults.node_description}
              rows="3"
            />
            <p class="-mt-1 text-xs text-base-content/60">
              Empty uses “{@defaults.node_description}”
            </p>
          </div>
          <button
            id="save-instance"
            type="submit"
            class="btn btn-primary"
            phx-disable-with="Saving…"
          >
            Save
          </button>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
