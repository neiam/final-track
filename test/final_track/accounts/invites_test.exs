defmodule FinalTrack.Accounts.InvitesTest do
  use FinalTrack.DataCase, async: true

  import FinalTrack.AccountsFixtures

  alias FinalTrack.Accounts
  alias FinalTrack.Accounts.Invite

  test "create_invite/2 with no owner, a note and a lifetime" do
    assert {:ok, invite} = Accounts.create_invite(nil, %{note: "for Sam", days: 7})
    assert invite.created_by_id == nil
    assert invite.note == "for Sam"
    assert DateTime.diff(invite.expires_at, DateTime.utc_now(), :day) in 6..7
    assert Invite.active?(invite)
  end

  test "create_invite_from_cli/1 resolves --by to an owner" do
    user = user_fixture()
    assert {:ok, invite} = Accounts.create_invite_from_cli(by: user.email, note: "x")
    assert invite.created_by_id == user.id
    assert {:error, :no_such_user} = Accounts.create_invite_from_cli(by: "nobody@example.com")
  end

  test "get_active_invite/1 ignores consumed, revoked and expired invites" do
    user = user_fixture()
    {:ok, active} = Accounts.create_invite(user)
    {:ok, used} = Accounts.create_invite(user)
    {:ok, _} = Accounts.consume_invite(used, user_fixture())
    {:ok, revoked} = Accounts.create_invite(user)
    {:ok, _} = Accounts.revoke_invite(user, revoked.id)

    {:ok, expired} =
      Accounts.create_invite(user, %{expires_at: DateTime.add(DateTime.utc_now(:second), -60)})

    assert Accounts.get_active_invite(active.token).id == active.id
    refute Accounts.get_active_invite(used.token)
    refute Accounts.get_active_invite(revoked.token)
    refute Accounts.get_active_invite(expired.token)
    refute Accounts.get_active_invite(nil)
  end

  describe "tokens at rest" do
    test "only a hash of the token is stored; the raw one finds it" do
      {:ok, invite} = Accounts.create_invite(nil)
      assert is_binary(invite.token)

      stored = FinalTrack.Repo.get!(Invite, invite.id)
      assert stored.token == nil
      assert stored.token_hash == Invite.hash_token(invite.token)

      %{rows: [row]} =
        FinalTrack.Repo.query!("SELECT * FROM invites WHERE id = $1", [
          Ecto.UUID.dump!(invite.id)
        ])

      refute Enum.any?(row, &(is_binary(&1) and &1 =~ invite.token))

      assert Accounts.get_active_invite(invite.token).id == invite.id
      refute Accounts.get_active_invite(Base.url_encode64(stored.token_hash, padding: false))
    end

    test "rotating replaces the hash, so the old link stops working" do
      owner = user_fixture()
      {:ok, invite} = Accounts.create_invite(owner)
      {:ok, rotated} = Accounts.rotate_invite(owner, invite.id)

      assert FinalTrack.Repo.get!(Invite, invite.id).token_hash ==
               Invite.hash_token(rotated.token)

      refute Accounts.get_active_invite(invite.token)
      assert Accounts.get_active_invite(rotated.token).id == invite.id
    end

    test "tokens keep their link shape" do
      {raw, hash} = Invite.build_token()
      assert raw =~ ~r/^[A-Za-z0-9_-]{32}$/
      assert hash == :crypto.hash(:sha256, raw)
    end
  end

  test "revoke_invite/2 only touches the owner's own active invites" do
    owner = user_fixture()
    {:ok, invite} = Accounts.create_invite(owner)

    assert {:error, :not_found} = Accounts.revoke_invite(user_fixture(), invite.id)
    assert {:error, :not_found} = Accounts.revoke_invite(owner, "not-a-uuid")

    assert {:ok, %{consumed_by_id: nil, consumed_at: %DateTime{}}} =
             Accounts.revoke_invite(owner, invite.id)

    assert {:error, :not_found} = Accounts.revoke_invite(owner, invite.id)
  end

  describe "addressed invites" do
    test "create_invite_from_cli/1 takes an email" do
      assert {:ok, %Invite{email: "sam@example.com"}} =
               Accounts.create_invite_from_cli(email: " sam@example.com ")

      assert {:error, %Ecto.Changeset{}} = Accounts.create_invite_from_cli(email: "nope")
    end

    test "rotate_invite/2 only replaces the owner's own active links" do
      owner = user_fixture()
      {:ok, invite} = Accounts.create_invite(owner)

      assert {:error, :not_found} = Accounts.rotate_invite(user_fixture(), invite.id)
      assert {:ok, rotated} = Accounts.rotate_invite(owner, invite.id)
      assert rotated.token != invite.token
      refute Accounts.get_active_invite(invite.token)

      {:ok, _} = Accounts.revoke_invite(owner, invite.id)
      assert {:error, :not_found} = Accounts.rotate_invite(owner, invite.id)
    end

    test "rotate_invite_for_email/1 finds the active invite for that address" do
      {:ok, invite} = Accounts.create_invite(nil, %{email: "Sam@Example.com"})

      assert {:ok, rotated} = Accounts.rotate_invite_for_email("sam@example.com")
      assert rotated.id == invite.id and rotated.token != invite.token
      assert {:error, :not_found} = Accounts.rotate_invite_for_email("other@example.com")
    end

    test "register_by_invite/2 creates a confirmed user and spends the invite" do
      {:ok, invite} = Accounts.create_invite(nil, %{email: "new@example.com"})

      attrs = %{
        "password" => valid_user_password(),
        "password_confirmation" => valid_user_password(),
        "email" => "ignored@example.com"
      }

      assert {:ok, user} = Accounts.register_by_invite(invite.token, attrs)
      assert user.email == "new@example.com"
      assert user.confirmed_at
      assert Accounts.get_user_by_email_and_password("new@example.com", valid_user_password())
      assert {:error, :invalid} = Accounts.register_by_invite(invite.token, attrs)
    end

    test "register_by_invite/2 refuses an email that has an account" do
      existing = user_fixture()
      {:ok, invite} = Accounts.create_invite(nil, %{email: existing.email})

      assert {:error, :has_account} =
               Accounts.register_by_invite(invite.token, %{
                 "password" => valid_user_password(),
                 "password_confirmation" => valid_user_password()
               })

      assert Invite.active?(FinalTrack.Repo.get!(Invite, invite.id))
    end

    test "register_by_invite/2 rolls back on a bad password, leaving the invite" do
      {:ok, invite} = Accounts.create_invite(nil, %{email: "new2@example.com"})

      assert {:error, %Ecto.Changeset{}} =
               Accounts.register_by_invite(invite.token, %{
                 "password" => "short"
               })

      refute Accounts.get_user_by_email("new2@example.com")
      assert Invite.active?(FinalTrack.Repo.get!(Invite, invite.id))
    end
  end
end
