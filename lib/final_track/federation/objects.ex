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

  Notes are unlisted by default (followers' timelines, not public ones): an
  account posts every play, which would flood local and federated
  timelines. An account can choose public instead (`Account.visibilities/0`).
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
      "name" => FinalTrack.Instance.node_name(),
      "summary" => "<p>#{escape(FinalTrack.Instance.node_description())}</p>",
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
      "to" => to(account),
      "cc" => cc(account),
      "sensitive" => false,
      "content" => content(s) <> hashtag_html(hashtags(account, s)),
      "tag" => hashtag_tags(hashtags(account, s)),
      # Its own URL, unique per post: Pixelfed treats posts sharing a url as
      # one and drops the rest. A browser following it lands on the profile.
      "url" => url,
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

  # The post's hashtags, as Mastodon writes them: links at the end of the
  # content, and Hashtags in `tag` (what servers index, filter and send to
  # tag-followers). The account's own tag, then (if it asks) the artist's.
  defp hashtag_html(tags) when tags == [], do: ""

  # Three spaces before the tags' paragraph: invisible where the HTML is
  # rendered (Mastodon), but where it's stripped to text (Pixelfed) the
  # title and the tags would otherwise run together.
  defp hashtag_html(tags) do
    links =
      Enum.map_join(tags, " ", fn tag ->
        ~s(<a href="#{tag_url(tag)}" class="mention hashtag" rel="tag">#<span>#{escape(tag)}</span></a>)
      end)

    "   <p>" <> links <> "</p>"
  end

  defp hashtag_tags(tags),
    do: Enum.map(tags, &%{"type" => "Hashtag", "href" => tag_url(&1), "name" => "#" <> &1})

  defp hashtags(%Account{} = account, scrobble) do
    own = if account.hashtag in [nil, ""], do: [], else: [account.hashtag]

    artist =
      if account.tag_artist, do: List.wrap(artist_hashtag(scrobble.track.artist.name)), else: []

    Enum.uniq_by(own ++ artist, &String.downcase/1)
  end

  @doc "An artist's name as a hashtag; see `FinalTrack.Catalog.hashtag/1`."
  def artist_hashtag(name), do: FinalTrack.Catalog.hashtag(name)

  defp tag_url(tag), do: base() <> "/tags/" <> URI.encode(String.downcase(tag))

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
      "to" => to(account),
      "cc" => cc(account),
      "object" => %{"id" => note_url(post), "type" => "Tombstone"}
    }
  end

  # Public: to everyone, cc followers. Unlisted: to followers, cc everyone
  # (delivered alike, kept off public timelines and others' profile views).
  defp to(%Account{visibility: "public"}), do: [@public]
  defp to(account), do: [followers_url(account)]

  defp cc(%Account{visibility: "public"} = account), do: [followers_url(account)]
  defp cc(_account), do: [@public]

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

  @nodeinfo_versions ["2.1", "2.0"]
  # The software's own home: what NodeInfo 2.1 reports for every server
  # running it, so not the instance's address.
  @repository "https://gg.neiam.co/r/neiam/final_track"

  def nodeinfo_versions, do: @nodeinfo_versions

  @doc "`/.well-known/nodeinfo`: where each schema version is served."
  def nodeinfo_links do
    %{
      "links" =>
        for v <- @nodeinfo_versions do
          %{
            "rel" => "http://nodeinfo.diaspora.software/ns/schema/" <> v,
            "href" => base() <> "/nodeinfo/" <> v
          }
        end
    }
  end

  @doc """
  The NodeInfo document, `version` "2.1" or "2.0". The software name must
  match `^[a-z0-9-]+$` (the schema), hence "finaltrack"; 2.1 adds where the
  software lives. The node's name and description are `FinalTrack.Instance`'s.
  """
  def nodeinfo(%{users: users, posts: posts}, version \\ "2.1")
      when version in @nodeinfo_versions do
    software = %{
      "name" => "finaltrack",
      "version" => :final_track |> Application.spec(:vsn) |> to_string()
    }

    software =
      if version == "2.1",
        do: Map.merge(software, %{"repository" => @repository, "homepage" => @repository}),
        else: software

    %{
      "version" => version,
      "software" => software,
      "protocols" => ["activitypub"],
      "services" => %{"inbound" => [], "outbound" => []},
      "openRegistrations" => FinalTrack.Accounts.registration_open?(),
      "usage" => %{"users" => %{"total" => users}, "localPosts" => posts},
      "metadata" => %{
        "nodeName" => FinalTrack.Instance.node_name(),
        "nodeDescription" => FinalTrack.Instance.node_description()
      }
    }
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
