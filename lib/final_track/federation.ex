defmodule FinalTrack.Federation do
  @moduledoc """
  ActivityPub, off unless `config :final_track, FinalTrack.Federation,
  enabled: true` (`FINAL_TRACK_ACTIVITYPUB=true` in prod).

  With it on, each member may set up a fediverse account (`@name@host`) and
  switch it on. An account that's on posts every new play of its user that
  isn't private (`FinalTrack.Privacy`), as an unlisted Note with the album
  cover attached, to its followers. Plays older than `max_age_sec` when
  they arrive (a phone's offline queue draining days later) are recorded
  but not posted. Marking something private later withdraws (`Delete`s) the
  posts it now covers.

  Inbound, an account accepts `Follow` (answered with `Accept`), `Undo` of
  a follow, and `Delete` of an actor that's gone; everything else is
  ignored. Every inbound activity's HTTP signature is checked, and its key's
  owner must be the activity's actor.

  The protocol plumbing (signatures, guarded HTTP, the instance actor) is
  ported from angler.
  """
  import Ecto.Query, warn: false
  require Logger

  alias FinalTrack.Accounts.User
  alias FinalTrack.{Privacy, Repo}

  alias FinalTrack.Federation.{
    Account,
    Delivery,
    Follower,
    HTTP,
    HTTPSignature,
    InstanceActor,
    Objects,
    Post,
    RemoteActor
  }

  alias FinalTrack.Scrobbles.Scrobble

  @key_refresh_after_sec 24 * 3600

  defp config, do: Application.get_env(:final_track, __MODULE__, [])

  @doc "Whether ActivityPub is on, server-wide."
  def enabled?, do: Keyword.get(config(), :enabled, false) == true

  defp post_delay_ms, do: Keyword.get(config(), :post_delay_ms, 15_000)
  defp max_age_sec, do: Keyword.get(config(), :max_age_sec, 6 * 3600)

  ## Accounts

  @doc "`user`'s fediverse account, or nil."
  def get_account(%User{id: user_id}),
    do: Account |> Repo.get_by(user_id: user_id) |> Repo.preload(:user)

  @doc "A changeset for `user`'s account settings form (their account, or a new one)."
  def change_account(%User{} = user, attrs \\ %{}) do
    (get_account(user) || %Account{user_id: user.id})
    |> Account.validation_changeset(attrs)
  end

  @doc "Creates or updates `user`'s account (username, on/off)."
  def save_account(%User{} = user, attrs) do
    (get_account(user) || %Account{user_id: user.id})
    |> Account.changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, account} -> {:ok, Repo.preload(account, :user, force: true)}
      error -> error
    end
  end

  @doc "A switched-on account by username, while federation is on; else nil."
  def get_live_account(username) when is_binary(username) do
    if enabled?() do
      from(a in Account,
        where: a.username == ^String.downcase(username) and a.enabled,
        preload: :user
      )
      |> Repo.one()
    end
  end

  def get_live_account(_), do: nil

  def follower_count(%Account{id: id}),
    do: Repo.aggregate(from(f in Follower, where: f.account_id == ^id), :count)

  def post_count(%Account{id: id}),
    do: Repo.aggregate(from(p in Post, where: p.account_id == ^id), :count)

  @doc "Numbers for NodeInfo: switched-on accounts and their posts."
  def usage do
    %{
      users: Repo.aggregate(from(a in Account, where: a.enabled), :count),
      posts:
        Repo.aggregate(from(p in Post, join: a in assoc(p, :account), where: a.enabled), :count)
    }
  end

  @doc "How `account` signs requests: `{key_id, private_key_pem}`."
  def signer(%Account{} = account), do: {Objects.key_id(account), account.private_key_pem}

  defp instance_signer do
    actor = InstanceActor.ensure!()
    {Objects.instance_actor_url() <> "#main-key", actor.private_key_pem}
  end

  def key_id(%Account{} = account), do: Objects.key_id(account)

  defp follower_inboxes(%Account{id: id}) do
    from(f in Follower,
      where: f.account_id == ^id,
      select: coalesce(f.shared_inbox, f.inbox),
      distinct: true
    )
    |> Repo.all()
  end

  ## Publishing

  @doc """
  Posts `scrobble_ids` (just recorded for `user`) from their account, if
  federation and the account are on: the ones anyone may see and recent
  enough. Delivery waits `post_delay_ms` (default 15s), so a cover being
  fetched for a new album can make it into the post.
  """
  def publish_plays(%User{} = user, scrobble_ids) when is_list(scrobble_ids) do
    with true <- enabled?() and scrobble_ids != [],
         %Account{enabled: true} = account <- get_account(user) do
      cutoff = DateTime.add(DateTime.utc_now(), -max_age_sec())

      ids =
        from(s in Scrobble,
          as: :scrobble,
          where: s.id in ^scrobble_ids and s.user_id == ^user.id and s.played_at >= ^cutoff,
          order_by: s.played_at,
          select: s.id
        )
        |> Privacy.visible_to(nil)
        |> Repo.all()

      now = DateTime.utc_now(:second)

      {_, posts} =
        Repo.insert_all(
          Post,
          Enum.map(
            ids,
            &%{
              id: FinalTrack.UUIDv7.generate(),
              account_id: account.id,
              scrobble_id: &1,
              inserted_at: now
            }
          ),
          on_conflict: :nothing,
          conflict_target: :scrobble_id,
          returning: [:id]
        )

      inboxes = follower_inboxes(account)

      if inboxes != [] do
        for %{id: post_id} <- posts do
          Delivery.send_later(
            inboxes,
            signer(account),
            fn -> create_for(post_id) end,
            post_delay_ms()
          )
        end
      end
    end

    :ok
  end

  # Built at send time: nil (nothing sent, and logged) if the play went
  # private meanwhile.
  # If the play's album is still waiting on its first cover lookup, give it
  # a little longer: a post without its cover is a post Pixelfed drops (it
  # doesn't store notes without media), and the cover is usually seconds
  # away. Then it goes as it is.
  defp create_for(post_id, waits \\ cover_waits()) do
    case get_post(post_id) do
      {:ok, %{scrobble: %{album: %{cover_key: nil, cover_checked_at: nil}}}} when waits > 0 ->
        Process.sleep(cover_wait_ms())
        create_for(post_id, waits - 1)

      {:ok, post} ->
        Objects.create(post, post.account)

      _ ->
        Logger.info("federation: post #{post_id} not sent: no longer showable")
        nil
    end
  end

  # Up to 4 × 15s more, on top of post_delay_ms.
  defp cover_waits, do: Keyword.get(config(), :cover_waits, 4)
  defp cover_wait_ms, do: Keyword.get(config(), :cover_wait_ms, 15_000)

  @doc """
  A post that may be shown: its account on, its play not private.
  `{:ok, post}` (scrobble, account and user loaded), `{:error, :gone}` for
  one that existed but mayn't be shown any more, or `{:error, :not_found}`.
  """
  def get_post(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Post{} = post <- Repo.get(Post, id) do
      visible? =
        from(s in Scrobble, as: :scrobble, where: s.id == ^post.scrobble_id)
        |> Privacy.visible_to(nil)
        |> Repo.exists?()

      post = Repo.preload(post, scrobble: [track: :artist, album: :artist], account: :user)

      if visible? and post.account.enabled and enabled?(),
        do: {:ok, post},
        else: {:error, :gone}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "An account's latest showable posts, newest first."
  def latest_posts(%Account{id: id} = account, limit \\ 20) do
    from(p in Post,
      join: s in Scrobble,
      on: s.id == p.scrobble_id,
      as: :scrobble,
      where: p.account_id == ^id,
      order_by: [desc: s.played_at],
      limit: ^limit,
      preload: [scrobble: [track: :artist, album: :artist]]
    )
    |> Privacy.visible_to(nil)
    |> Repo.all()
    |> Enum.map(&%{&1 | account: account})
  end

  @doc """
  Withdraws `user`'s posts that are private now (after a `Privacy.mark/2`):
  a `Delete` to followers, and the post is forgotten.
  """
  def retract_hidden(%User{} = user) do
    with true <- enabled?(), %Account{} = account <- get_account(user) do
      visible =
        from(p in Post,
          join: s in Scrobble,
          on: s.id == p.scrobble_id,
          as: :scrobble,
          where: p.account_id == ^account.id,
          select: p.id
        )
        |> Privacy.visible_to(nil)

      hidden =
        from(p in Post, where: p.account_id == ^account.id and p.id not in subquery(visible))
        |> Repo.all()

      if hidden != [] do
        inboxes = follower_inboxes(account)

        for post <- hidden,
            inboxes != [],
            do: Delivery.send_now(inboxes, signer(account), Objects.delete(post, account))

        Repo.delete_all(from(p in Post, where: p.id in ^Enum.map(hidden, & &1.id)))
      end
    end

    :ok
  end

  ## Inbox

  @doc """
  Handles an activity POSTed to an inbox. `request` is `%{method:, path:,
  headers: [{name, value}], raw_body:}` (header names lowercase, `host`
  included). `:ok` (handled or ignored), `{:error, :unauthorized}` or
  `{:error, :bad_request}`.
  """
  def receive_activity(request, %{"type" => type, "actor" => actor} = activity)
      when is_binary(type) and is_binary(actor) do
    if actor_delete?(activity) do
      # Its key went with it, so it can't be verified: confirm instead.
      actor_gone(actor)
    else
      with :ok <- verify(request, actor), do: dispatch(activity)
    end
  end

  def receive_activity(_request, _activity), do: {:error, :bad_request}

  defp actor_delete?(%{"type" => "Delete", "actor" => actor, "object" => object}),
    do: object == actor or (is_map(object) and object["id"] == actor)

  defp actor_delete?(_), do: false

  # Only forget a follower whose actor really is gone (404/410). Unknown
  # actors (Mastodon tells every server about every deletion) cost nothing.
  defp actor_gone(actor) do
    if Repo.exists?(from(f in Follower, where: f.actor_id == ^actor)) do
      case HTTP.fetch(actor, signed_with: instance_signer()) do
        {:error, {:bad_status, status}} when status in [404, 410] ->
          Repo.delete_all(from(f in Follower, where: f.actor_id == ^actor))
          Repo.delete_all(from(r in RemoteActor, where: r.ap_id == ^actor))

        _ ->
          :ok
      end
    end

    :ok
  end

  defp verify(request, actor) do
    check = fn resolver ->
      HTTPSignature.verify(
        request.method,
        request.path,
        request.headers,
        request.raw_body,
        resolver
      )
    end

    result =
      case check.(&resolve_key(&1, false)) do
        # The key may have rotated: once more with a fresh copy.
        {:error, :bad_signature} -> check.(&resolve_key(&1, true))
        other -> other
      end

    signer_id = request.headers |> signature_key_id() |> owner_of_key()

    cond do
      result != :ok -> {:error, :unauthorized}
      signer_id != actor -> {:error, :unauthorized}
      true -> :ok
    end
  end

  defp signature_key_id(headers) do
    with {_, sig} <- List.keyfind(headers, "signature", 0),
         {:ok, %{"keyId" => key_id}} <- HTTPSignature.parse_signature_header(sig) do
      key_id
    else
      _ -> nil
    end
  end

  defp owner_of_key(nil), do: nil

  defp owner_of_key(key_id) do
    Repo.one(from(r in RemoteActor, where: r.public_key_id == ^key_id, select: r.ap_id, limit: 1))
  end

  # key id -> {:ok, pem} | :error, from the cache or the actor's document.
  defp resolve_key(key_id, refresh?) do
    cached = Repo.one(from(r in RemoteActor, where: r.public_key_id == ^key_id, limit: 1))

    if cached && cached.public_key_pem && !refresh? && fresh?(cached) do
      {:ok, cached.public_key_pem}
    else
      case fetch_actor(key_id) do
        {:ok, %RemoteActor{public_key_id: ^key_id, public_key_pem: pem}} when is_binary(pem) ->
          {:ok, pem}

        _ ->
          :error
      end
    end
  end

  defp fresh?(%RemoteActor{updated_at: at}),
    do: DateTime.diff(DateTime.utc_now(), at) < @key_refresh_after_sec

  @doc """
  Fetches (signed as the instance) and caches the actor behind an actor id
  or key id: its inboxes and key.
  """
  def fetch_actor(id) do
    url = id |> URI.parse() |> Map.put(:fragment, nil) |> URI.to_string()

    with {:ok, doc} <- HTTP.fetch(url, signed_with: instance_signer()),
         {:ok, doc} <- owner_doc(doc),
         {:ok, attrs} <- actor_attrs(doc) do
      %RemoteActor{}
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert(
        on_conflict:
          {:replace, [:inbox, :shared_inbox, :public_key_id, :public_key_pem, :updated_at]},
        conflict_target: :ap_id,
        returning: true
      )
    end
  end

  # Some servers' key ids point at a key document naming its owner.
  defp owner_doc(%{"owner" => owner, "publicKeyPem" => _} = key) when is_binary(owner) do
    with {:ok, actor} <- HTTP.fetch(owner, signed_with: instance_signer()) do
      {:ok, Map.put_new(actor, "publicKey", key)}
    end
  end

  defp owner_doc(doc), do: {:ok, doc}

  defp actor_attrs(%{"id" => id, "inbox" => inbox} = doc)
       when is_binary(id) and is_binary(inbox) do
    key = doc["publicKey"]
    key = if is_list(key), do: List.first(key), else: key
    # The key must belong to this actor, or anyone could vouch for anyone.
    key = if is_map(key) and key["owner"] in [nil, id], do: key, else: nil

    {:ok,
     %{
       ap_id: id,
       inbox: inbox,
       shared_inbox: get_in(doc, ["endpoints", "sharedInbox"]),
       public_key_id: key && key["id"],
       public_key_pem: key && key["publicKeyPem"]
     }}
  end

  defp actor_attrs(_), do: {:error, :not_an_actor}

  defp dispatch(%{"type" => "Follow", "actor" => actor, "object" => object} = follow) do
    with %Account{} = account <- account_for_url(object_id(object)),
         {:ok, remote} <- remote_actor(actor) do
      %Follower{}
      |> Ecto.Changeset.change(%{
        account_id: account.id,
        actor_id: actor,
        inbox: remote.inbox,
        shared_inbox: remote.shared_inbox
      })
      |> Repo.insert!(
        on_conflict: {:replace, [:inbox, :shared_inbox, :updated_at]},
        conflict_target: [:account_id, :actor_id]
      )

      Delivery.send_now([remote.inbox], signer(account), Objects.accept(follow, account))
      :ok
    else
      # Not one of ours, or an actor we can't read: nothing to do.
      _ -> :ok
    end
  end

  defp dispatch(%{"type" => "Undo", "actor" => actor, "object" => %{"type" => "Follow"} = follow}) do
    if follow["actor"] in [nil, actor] do
      case account_for_url(object_id(follow["object"])) do
        %Account{id: id} ->
          Repo.delete_all(
            from(f in Follower, where: f.account_id == ^id and f.actor_id == ^actor)
          )

        nil ->
          :ok
      end
    end

    :ok
  end

  defp dispatch(_activity), do: :ok

  defp remote_actor(actor) do
    case Repo.get_by(RemoteActor, ap_id: actor) do
      %RemoteActor{} = cached -> {:ok, cached}
      nil -> fetch_actor(actor)
    end
  end

  defp object_id(%{"id" => id}), do: id
  defp object_id(id) when is_binary(id), do: id
  defp object_id(_), do: nil

  defp account_for_url(url) when is_binary(url) do
    prefix = Objects.base() <> "/ap/users/"

    case String.split(url, prefix, parts: 2) do
      ["", username] -> get_live_account(username)
      _ -> nil
    end
  end

  defp account_for_url(_), do: nil
end
