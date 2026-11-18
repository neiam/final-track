defmodule FinalTrack.Federation.Delivery do
  @moduledoc """
  Sends activities to remote inboxes, one supervised task per inbox.

  A delivery that fails transiently (408, 429, 5xx, a timeout, DNS) is
  retried after each of `@backoff_ms`; anything else (the server said no)
  is dropped and logged. Retries live in memory: a restart loses whatever
  was pending, which for "now playing" posts is an acceptable loss. (angler
  uses Oban jobs for this; worth the same here if posts ever matter more.)

  `config :final_track, FinalTrack.Federation, delivery: :inline` runs each
  delivery in the caller, once, with no retries (tests).
  """
  require Logger

  alias FinalTrack.Federation.HTTP

  @backoff_ms [60_000, 5 * 60_000, 30 * 60_000]

  @doc """
  Sends `build.()` to each inbox, signed with `signer` (`{key_id, pem}`),
  after `delay_ms`. `build` runs once, after the delay, so a Note reflects
  the play as it is then (a cover fetched meanwhile, or nothing at all if
  it was made private: `build` returns nil and nothing is sent).
  """
  def send_later(inboxes, signer, build, delay_ms \\ 0) when is_function(build, 0) do
    run(fn ->
      if delay_ms > 0 and not inline?(), do: Process.sleep(delay_ms)

      case build.() do
        nil -> :ok
        activity -> Enum.each(Enum.uniq(inboxes), &send_one(&1, activity, signer))
      end
    end)
  end

  @doc "Sends `activity` to each inbox now (with retries)."
  def send_now(inboxes, signer, activity), do: send_later(inboxes, signer, fn -> activity end)

  # Each inbox in its own task, so one slow server holds up nobody else.
  defp send_one(inbox, activity, signer) do
    run(fn -> attempt(inbox, activity, signer, @backoff_ms) end)
  end

  defp attempt(inbox, activity, signer, backoff) do
    case HTTP.deliver(inbox, activity, signer) do
      :ok ->
        :ok

      {:error, reason} ->
        case {HTTP.transient_error?(reason), backoff, inline?()} do
          {true, [wait | rest], false} ->
            Process.sleep(wait)
            attempt(inbox, activity, signer, rest)

          _ ->
            Logger.warning(
              "federation: #{activity["type"]} to #{inbox} failed: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  defp run(fun) do
    if inline?() do
      fun.()
    else
      Task.Supervisor.start_child(FinalTrack.Federation.TaskSupervisor, fun)
    end

    :ok
  end

  defp inline?,
    do:
      Application.get_env(:final_track, FinalTrack.Federation, []) |> Keyword.get(:delivery) ==
        :inline
end
