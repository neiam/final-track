defmodule FinalTrack.Federation.Objects do
  @moduledoc """
  The ActivityPub documents final_track serves and sends: actors, Notes for
  plays, the activities that carry them, WebFinger and NodeInfo.

  URLs, under the endpoint's public URL:

    * `/ap/actor`                    the instance actor (Application)
    * `/ap/users/:username`          an account (Service: its posts are automated)
    * `/ap/users/:username/inbox`    …and its inbox, `/outbox`, `/followers`
    * `/ap/inbox`                    the shared inbox
    * `/ap/notes/:id`                a posted play

  Notes are unlisted (followers' timelines, not public ones): an account
  posts every play, which would flood local and federated timelines.
  """

  alias FinalTrack.Accounts.User
  alias FinalTrack.Federation.{Account, InstanceActor, Post}
  alias FinalTrackWeb.MusicComponents

  @public "https://www.w3.org/ns/activitystreams#Public"
  @context ["https://www.w3.org/ns/activitystreams", "https://w3id.org/security/v1"]

  def base, do: FinalTrackWeb.base_url()
  def domain, do: URI.parse(base()).host

  ## URLs

  def instance_actor_url, do: base() <> "/ap/actor"
  def actor_url(%Account{username: username}), do: base() <> "/ap/users/" <> username

  @doc "The account's profile page, Mastodon-style: `/@username`."
  def profile_url(%Account{username: username}), do: base() <> "/@" <> username
  def key_id(%Account{} = account), do: actor_url(account) <> "#main-key"
  def followers_url(%Account{} = account), do: actor_url(account) <> "/followers"
  def note_url(%Post{id: id}), do: base() <> "/ap/notes/" <> id
  def shared_inbox_url, do: base() <> "/ap/inbox"

  ## Actors

  @doc "The instance actor's document."
  def instance_actor(%InstanceActor{} = actor) do
    url = instance_actor_url()

    %{
      "@context" => @context,
      "id" => url,
      "type" => "Application",
      "preferredUsername" => domain(),
      "name" => domain(),
      "summary" => "The Final Track server at #{domain()}.",
      "inbox" => url <> "/inbox",
      "outbox" => url <> "/outbox",
      "url" => base() <> "/about",
      "manuallyApprovesFollowers" => true,
      "publicKey" => %{
        "id" => url <> "#main-key",
        "owner" => url,
        "publicKeyPem" => actor.public_key_pem
      }
    }
  end

  @doc "An account's actor document. `account.user` must be loaded."
  def person(%Account{user: %User{} = user} = account) do
    url = actor_url(account)
    name = User.display_name(user)

    %{
      "@context" => @context,
      "id" => url,
      "type" => "Service",
      "preferredUsername" => account.username,
      "name" => name,
      "summary" =>
        "<p>What #{escape(name)} is listening to, scrobbled to Final Track at #{escape(domain())}.</p>",
      "url" => profile_url(account),
      "inbox" => url <> "/inbox",
      "outbox" => url <> "/outbox",
      "followers" => url <> "/followers",
      "manuallyApprovesFollowers" => false,
      "discoverable" => false,
      "published" => DateTime.to_iso8601(account.inserted_at),
      "endpoints" => %{"sharedInbox" => shared_inbox_url()},
      "publicKey" => %{
        "id" => key_id(account),
        "owner" => url,
        "publicKeyPem" => account.public_key_pem
      }
    }
  end

  ## Plays

  @doc """
  The Note for a posted play. `post.scrobble` must be loaded with `track:
  :artist` and `album: :artist`. The album cover, when there is one, is
  attached as an image.
  """
  def note(%Post{} = post, %Account{} = account) do
    s = post.scrobble
    url = note_url(post)

    %{
      "@context" => @context,
      "id" => url,
      "type" => "Note",
      "attributedTo" => actor_url(account),
      "published" => DateTime.to_iso8601(s.played_at),
      "to" => [followers_url(account)],
      "cc" => [@public],
      "sensitive" => false,
      "content" => content(s),
      # Where "open original" goes: the profile, which shows the play.
      "url" => profile_url(account),
      "attachment" => cover_attachment(s.album, s.track)
    }
  end

  defp content(scrobble) do
    track =
      "<strong>#{escape(scrobble.track.title)}</strong> by #{escape(scrobble.track.artist.name)}"

    album =
      if scrobble.album, do: "<br>from <em>#{escape(scrobble.album.title)}</em>", else: ""

    "<p>🎵 #{track}#{album}</p>"
  end

  defp cover_attachment(nil, _track), do: []

  defp cover_attachment(album, _track) do
    case MusicComponents.cover_url(album) do
      nil ->
        []

      path ->
        [
          %{
            "type" => "Document",
            "mediaType" => FinalTrack.Covers.Image.content_type(album.cover_key),
            "url" => base() <> path,
            "name" => "Cover of #{album.title} by #{album.artist.name}"
          }
        ]
    end
  end

  @doc "The `Create` that delivers a Note."
  def create(%Post{} = post, %Account{} = account) do
    note = post |> note(account) |> Map.delete("@context")

    %{
      "@context" => @context,
      "id" => note_url(post) <> "/activity",
      "type" => "Create",
      "actor" => actor_url(account),
      "published" => note["published"],
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note
    }
  end

  @doc "The `Delete` that withdraws a Note (it became private)."
  def delete(%Post{} = post, %Account{} = account) do
    %{
      "@context" => @context,
      "id" => note_url(post) <> "#delete",
      "type" => "Delete",
      "actor" => actor_url(account),
      "to" => [followers_url(account)],
      "cc" => [@public],
      "object" => %{"id" => note_url(post), "type" => "Tombstone"}
    }
  end

  @doc "The `Accept` answering a `Follow`."
  def accept(follow, %Account{} = account) do
    %{
      "@context" => @context,
      "id" => actor_url(account) <> "#accepts/follows/" <> Ecto.UUID.generate(),
      "type" => "Accept",
      "actor" => actor_url(account),
      "object" => follow
    }
  end

  @doc "An outbox: how many plays were posted, and the latest few."
  def outbox(%Account{} = account, total, latest_posts) do
    %{
      "@context" => @context,
      "id" => actor_url(account) <> "/outbox",
      "type" => "OrderedCollection",
      "totalItems" => total,
      "orderedItems" => Enum.map(latest_posts, &(&1 |> create(account) |> Map.delete("@context")))
    }
  end

  @doc "A followers collection: the count only, never the list."
  def followers(%Account{} = account, total) do
    %{
      "@context" => @context,
      "id" => followers_url(account),
      "type" => "OrderedCollection",
      "totalItems" => total
    }
  end

  ## Discovery

  @doc "The WebFinger document for an account."
  def webfinger(%Account{} = account) do
    %{
      "subject" => "acct:#{account.username}@#{domain()}",
      "aliases" => [actor_url(account), profile_url(account)],
      "links" => [
        %{"rel" => "self", "type" => "application/activity+json", "href" => actor_url(account)},
        %{
          "rel" => "http://webfinger.net/rel/profile-page",
          "type" => "text/html",
          "href" => profile_url(account)
        }
      ]
    }
  end

  @doc "The WebFinger document for the instance actor (`acct:domain@domain`)."
  def instance_webfinger do
    %{
      "subject" => "acct:#{domain()}@#{domain()}",
      "aliases" => [instance_actor_url()],
      "links" => [
        %{"rel" => "self", "type" => "application/activity+json", "href" => instance_actor_url()}
      ]
    }
  end

  def nodeinfo_links do
    %{
      "links" => [
        %{
          "rel" => "http://nodeinfo.diaspora.software/ns/schema/2.0",
          "href" => base() <> "/nodeinfo/2.0"
        }
      ]
    }
  end

  def nodeinfo(%{users: users, posts: posts}) do
    %{
      "version" => "2.0",
      "software" => %{
        "name" => "final_track",
        "version" => :final_track |> Application.spec(:vsn) |> to_string()
      },
      "protocols" => ["activitypub"],
      "services" => %{"inbound" => [], "outbound" => []},
      "openRegistrations" => FinalTrack.Accounts.registration_open?(),
      "usage" => %{"users" => %{"total" => users}, "localPosts" => posts},
      "metadata" => %{}
    }
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
