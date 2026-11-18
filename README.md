# Final Track

A self-hosted scrobble server for you and your people. Phones running
[Scropple](https://gg.neiam.co/r/neiam/scropple-android) (or anything that
speaks its HTTP backend's JSON) post what they play; members see charts by
day, week, month and year, a library of every artist and album with its
numbers, and a live wall of album art on the front page.

Running at **https://finaltrack.neiam.org** (deployment:
`argo-01-bos/finaltrack`). Phoenix 1.8 / LiveView, PostgreSQL.

## What's in it

- **Scrobbling API.** `POST /api/v1/scrobble` and `/api/v1/now-playing`,
  the same contract ircd's ScrobbleServ accepts, so one phone can feed both
  (and Last.fm) at once. Per-device bearer tokens, made and revoked on the
  Scrobbling page; only their hashes are stored.
- **Charts** (`/charts`): top artists, albums and tracks for any day, week,
  month or year, plays over time, who's listening now, latest plays.
  Periods follow the viewer's time zone (Postgres does the zone math).
  Everyone's, or just yours.
- **Library** (`/artists`, `/albums`): everything that's been played, with
  plays, listeners, tracks, first and last played. Sort, search, scroll.
- **Landing grid** (`/`): the latest plays as album art, live. Public:
  visitors see what was played, members also see who.
- **Covers**: uploaded on the album page, or fetched from MusicBrainz and
  the Cover Art Archive (automatically the first time an album is played;
  a collaboration credit like "Justice & Tame Impala" falls back to the
  main artist).
- **Private marks**: mark an artist, album or track private and your plays
  of it are only ever shown to you — past ones included, everywhere,
  fediverse posts too.
- **Fediverse** (optional, off by default): a member can give their plays
  an account (`@name@host`) that Mastodon, Pixelfed and others can follow;
  each non-private play is posted with its cover, followers-only or public,
  tagged `#scropple` by default (changeable, or off) so people who'd rather
  not see a post per play can filter the tag, and optionally the artist
  (`Pink Floyd` → `#pinkfloyd`). `/@name` is the profile; `/tags/<tag>`
  lists what public accounts here posted under a tag.
- **Accounts**: invite-only registration, email/password and magic links
  (`phx.gen.auth`), optional OpenID Connect sign-in via
  [`neiam_auth`](https://gg.neiam.co/neiam/neiam_auth).

## The scrobbling API

```sh
curl -X POST https://HOST/api/v1/scrobble \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '[{"artist": "Pink Floyd", "track": "Time",
        "album": "The Dark Side of the Moon",
        "durationSec": 413, "timestamp": 1763494445}]'
```

- Body: one object, a bare array, or `{"scrobbles": [...]}` (up to 500).
  `artist` and `track` are required; `album`, `albumArtist`, `durationSec`
  and `timestamp` (Unix seconds, when the play started) are optional.
- Answers `200 {"accepted": n, "rejected": m}`; all invalid is a `422`. A
  retried batch adds nothing: plays are unique per user, track and time.
- `POST /api/v1/now-playing` takes one object and answers `204`.
- Every bad or missing token is the same `401`.

## Who sees what

| Viewer | Sees |
|---|---|
| Anyone | the landing grid: what was played and when, never by whom |
| Anyone, for a member with a fediverse account | that account's non-private plays on `/@name` and, if it posts publicly, under `/tags/<tag>` |
| Members | charts, library, album and artist pages, who played what |
| Fediverse followers | a member's non-private plays, if they turned an account on |
| You | everything you've played |

Everything shared is filtered by `FinalTrack.Privacy.visible_to/2` at read
time, which is why marking something private also hides the past.

## Fediverse

Off unless `FINAL_TRACK_ACTIVITYPUB=true`; then each member opts in on the
Scrobbling page with a username, and chooses:

- **Who sees the posts.** Followers' feeds only (unlisted, the default) or
  public. Pixelfed and angler show only public posts on a remote profile
  and only backfill public ones, so an unlisted account looks empty there
  although followers get every post.
- **A hashtag** on every post, `#scropple` by default; empty for none.
- **The artist as a hashtag** too (off by default).

Each new play that isn't private becomes a Note with the album cover
attached, delivered to followers about 15 seconds after the scrobble (up
to a minute more if the album's first cover lookup is still running:
Pixelfed drops posts without media). Plays more than 6 hours old when
they arrive — a phone's offline queue draining — are recorded but not
posted. Marking something private sends a `Delete` for what it now covers.

Served: `/.well-known/webfinger` (`acct:user@host`, `acct:@user@host`, or
the actor or `/@user` URL), `/.well-known/host-meta`, `/.well-known/nodeinfo`
with `/nodeinfo/2.1` and `/2.0` (software `finaltrack`; the node's name and
description are the admin's, see Admins), the instance actor `/ap/actor`, accounts under
`/ap/users/:name` (inbox, outbox, followers), posts at `/ap/notes/:id`, the
shared inbox `/ap/inbox`. Inbound: `Follow`, `Undo` of one, `Delete` of an
actor that's gone; every request's HTTP signature is checked.

Every delivery is logged as a `federation:` line with the inbox and the
status it got (retries included). Remote servers answer 2xx and process
later in their own queues, so a post that "never showed up" may just be
waiting there.

## Development

```sh
podman compose up -d        # Postgres on localhost:54330 (docker works too)
mix setup                   # deps, database, assets
mix phx.server              # http://localhost:4000
mix final_track.invite      # a registration link (invite-only by default)
```

Before committing: `mix precommit` (warnings as errors, unused deps,
format, tests). Tests use the compose Postgres too; `POSTGRES_PORT=5432`
points them at a host Postgres instead. Outbound HTTP (MusicBrainz, other
fediverse servers) is stubbed with `Req.Test` in tests.

In dev, covers are stored under `priv/uploads/` and fetched automatically,
so scrobbling locally makes real requests to MusicBrainz.

## Running it

The image is built by `.forgejo/workflows/image.yml` on every push to
master: `ggr.neiam.co/neiam/final_track:{master,latest,sha-…}`. The release
(`mix release`) ships these scripts in `bin/`:

| Script | |
|---|---|
| `server` | start the app (`PHX_SERVER=true`) |
| `migrate` | run migrations (an init container in Kubernetes) |
| `invite [--email E] [--note N] [--days D] [--by E]` | print a single-use registration link |
| `invite-link EMAIL` | a fresh link for an invite addressed to EMAIL |
| `admin [--revoke] EMAIL` | make an account an admin (or not) |
| `final_track rpc 'FinalTrack.Covers.retry_misses()'` | look up covers again for albums that never matched |

The About page has copy-ready Podman/Docker commands for a single box.

### Configuration (env, read at boot)

| Variable | Default | |
|---|---|---|
| `PHX_HOST` | — | public host; also the domain fediverse accounts live on |
| `SECRET_KEY_BASE` | — | required, 64+ bytes |
| `POSTGRES_HOST`, `_PORT`, `_USER`, `_PASSWORD`, `_DB` | — | preferred (passwords with URL characters survive) |
| `DATABASE_URL` | — | used when `POSTGRES_HOST` isn't set |
| `PORT`, `POOL_SIZE` | `4000`, `10` | |
| `FINAL_TRACK_COVERS_DIR` | `/var/lib/final_track/covers` | shared between replicas |
| `FINAL_TRACK_AUTO_FETCH_COVERS` | `true` | look up a cover the first time an album is played |
| `FINAL_TRACK_COVER_INTERVAL_MS` | `2200` | between MusicBrainz requests, per pod (its limit is ~1/s per IP) |
| `FINAL_TRACK_MUSICBRAINZ_USER_AGENT` | `FinalTrack/0.1 (self-hosted scrobble server)` | put a URL or address to reach you in it |
| `FINAL_TRACK_ACTIVITYPUB` | `false` | fediverse accounts; settle `PHX_HOST` first |
| `SMTP_RELAY`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_SSL`, `SMTP_TLS`, `SMTP_AUTH` | — | mail. Optional: without a relay (and, if it needs auth, a password) mail is off — no emailed links, registration takes a password |
| `MAIL_FROM_ADDRESS`, `MAIL_FROM_NAME` | `noreply@PHX_HOST`, `Final Track` | |
| `OIDC_ENABLED`, `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, … | off | see `neiam_auth`'s README; `OIDC_LOGIN_MODE` picks how SSO and passwords coexist |
| `FINAL_TRACK_NODE_NAME`, `FINAL_TRACK_NODE_DESCRIPTION` | `Final Track`, a one-liner | what NodeInfo and the instance's fediverse actor call the server; an admin's Instance page overrides them |
| `FINAL_TRACK_ADMIN_GROUP` | `admins` | members of this OIDC group become admins on sign-in |
| `CLUSTER_NAMESPACE`, `POD_IP`, `RELEASE_COOKIE` | — | clustering in Kubernetes (below) |

### Admins

Admins get an **Instance** page (`/admin/instance`, in the account menu)
for the server's name and description. Members of the OIDC admin group
become admins when they sign in with SSO; elsewhere, `bin/admin EMAIL` (or
`mix final_track.admin EMAIL` in dev). Leaving the group doesn't demote
anyone — `bin/admin --revoke EMAIL` does.

### Clustering

With `CLUSTER_NAMESPACE` set, libcluster lists that namespace's pods
labelled `name=finaltrack` and connects to `final_track@<pod ip>`
(`rel/env.sh.eex`, from `POD_IP`); `RELEASE_COOKIE` must match across
pods. PubSub then spans every replica, so a scrobble landing on one pod
updates pages served by another. Each pod runs its own cover-lookup queue
and ActivityPub deliveries; covers must be on a volume all pods share.

## Where things are

| | |
|---|---|
| `FinalTrack.Scrobbles` | the API's validation, recording, now playing, tokens |
| `FinalTrack.Catalog` | artists, albums, tracks (matched on normalised names) |
| `FinalTrack.Charts` (+ `Charts.Period`) | every count: periods, timelines, library, summaries |
| `FinalTrack.Privacy` | private marks and the visibility rule |
| `FinalTrack.Covers` (+ `Fetcher`, `Queue`, `Store`, `Image`) | cover upload, lookup, storage |
| `FinalTrack.Federation` (+ `Objects`, `HTTP`, `HTTPSignature`, `Delivery`) | ActivityPub; signatures and guarded HTTP ported from angler |
| `FinalTrackWeb.FederationController`, `ProfileController`, `TagController` | the ActivityPub endpoints, `/@name`, `/tags/:tag` |
| `FinalTrackWeb.Api.ScrobbleController`, `Plugs.ScrobbleAuth` | the scrobbling API |
| `FinalTrack.Accounts` | users, invites, display names, admins |
| `FinalTrack.Instance` | the server's name and description |
| `FinalTrack.Release` | what `bin/migrate`, `bin/invite` run |
