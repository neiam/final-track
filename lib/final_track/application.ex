defmodule FinalTrack.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        FinalTrackWeb.Telemetry,
        FinalTrack.Repo,
        # Sign in with NEIAM: inert unless OIDC_ENABLED=true; then one
        # provider worker that loads discovery/JWKS in the background, so an
        # unreachable issuer never holds up boot.
        NeiamAuth,
        {DNSCluster, query: Application.get_env(:final_track, :dns_cluster_query) || :ignore}
      ] ++
        cluster_children(Application.get_env(:libcluster, :topologies, [])) ++
        [
          {Phoenix.PubSub, name: FinalTrack.PubSub},
          # Album cover lookups, one at a time (MusicBrainz rate limit).
          FinalTrack.Covers.Queue,
          # ActivityPub deliveries, one task per inbox (FinalTrack.Federation).
          {Task.Supervisor, name: FinalTrack.Federation.TaskSupervisor},
          # Start a worker by calling: FinalTrack.Worker.start_link(arg)
          # {FinalTrack.Worker, arg},
          # Start to serve requests, typically the last entry
          FinalTrackWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: FinalTrack.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  # libcluster, when runtime.exs configured a topology (prod in Kubernetes).
  defp cluster_children([]), do: []

  defp cluster_children(topologies),
    do: [{Cluster.Supervisor, [topologies, [name: FinalTrack.ClusterSupervisor]]}]

  @impl true
  def config_change(changed, _new, removed) do
    FinalTrackWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
