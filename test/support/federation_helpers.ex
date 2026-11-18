defmodule FinalTrack.FederationHelpers do
  @moduledoc """
  A fake fediverse server for tests: an actor with a real key pair, its
  documents served through `Req.Test`, and every POST to it forwarded to
  the test process as `{:delivered, inbox, activity, conn_headers}`.
  """
  import ExUnit.Assertions

  alias FinalTrack.Federation
  alias FinalTrack.Federation.{HTTPSignature, Keys}

  @remote "https://remote.example"

  def remote, do: @remote

  @doc "A remote actor: `%{id, key_id, inbox, shared_inbox, public_pem, private_pem}`."
  def remote_actor(name \\ "bob") do
    {public, private} = Keys.generate()
    id = "#{@remote}/users/#{name}"

    %{
      id: id,
      key_id: id <> "#main-key",
      inbox: id <> "/inbox",
      shared_inbox: @remote <> "/inbox",
      public_pem: public,
      private_pem: private
    }
  end

  def actor_doc(actor) do
    %{
      "id" => actor.id,
      "type" => "Person",
      "inbox" => actor.inbox,
      "endpoints" => %{"sharedInbox" => actor.shared_inbox},
      "publicKey" => %{
        "id" => actor.key_id,
        "owner" => actor.id,
        "publicKeyPem" => actor.public_pem
      }
    }
  end

  @doc """
  Serves the given actors' documents (GET), answers `gone` ids with 410,
  and forwards POSTs to the test process.
  """
  def stub_remote(actors, opts \\ []) do
    test = self()
    gone = Keyword.get(opts, :gone, [])
    docs = Map.new(actors, &{&1.id, actor_doc(&1)})

    Req.Test.stub(FinalTrack.Federation.HTTP, fn conn ->
      url = "https://#{conn.host}#{conn.request_path}"

      case conn.method do
        "GET" ->
          cond do
            url in gone ->
              Plug.Conn.send_resp(conn, 410, "")

            doc = docs[url] ->
              conn
              |> Plug.Conn.put_resp_content_type("application/activity+json")
              |> Plug.Conn.send_resp(200, Jason.encode!(doc))

            true ->
              Plug.Conn.send_resp(conn, 404, "")
          end

        "POST" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            test,
            {:delivered, url, Jason.decode!(body), conn.req_headers, body, conn.request_path}
          )

          Plug.Conn.send_resp(conn, 202, "")
      end
    end)
  end

  @doc "Asserts a delivery was signed by `account` (verified with its public key)."
  def assert_signed_by(account, headers, body, path) do
    headers = [{"host", "remote.example"} | headers]

    assert :ok =
             HTTPSignature.verify(:post, path, headers, body, fn key_id ->
               assert key_id == Federation.key_id(account)
               {:ok, account.public_key_pem}
             end)
  end

  @doc "Headers for a POST of `body` to `path` on our test endpoint, signed as `actor`."
  def signed_headers(actor, path, body) do
    {:ok, headers} =
      HTTPSignature.sign(:post, path, "www.example.com", body, actor.key_id, actor.private_pem, [
        {"Content-Type", "application/activity+json"}
      ])

    # Host is signed but travels on conn.host (www.example.com), not as a header.
    for {k, v} <- headers, String.downcase(k) != "host", do: {String.downcase(k), v}
  end

  @doc "A switched-on fediverse account for `user`."
  def fedi_account(user, username \\ "alice") do
    {:ok, account} = Federation.save_account(user, %{username: username, enabled: true})
    account
  end
end
