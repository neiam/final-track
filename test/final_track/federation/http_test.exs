defmodule FinalTrack.Federation.HTTPTest do
  # Changes app config: not async.
  use ExUnit.Case, async: false

  alias FinalTrack.Federation.HTTP

  test "private, loopback, link-local, CGNAT and reserved addresses are refused" do
    for ip <- [
          {127, 0, 0, 1},
          {10, 1, 2, 3},
          {172, 20, 0, 1},
          {192, 168, 1, 1},
          {169, 254, 169, 254},
          {100, 64, 0, 1},
          {0, 0, 0, 0},
          {0, 0, 0, 0, 0, 0, 0, 1},
          {0xFE80, 0, 0, 0, 0, 0, 0, 1},
          {0xFC00, 0, 0, 0, 0, 0, 0, 1},
          {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
        ] do
      assert HTTP.private_ip?(ip), inspect(ip)
    end

    refute HTTP.private_ip?({93, 184, 216, 34})
    refute HTTP.private_ip?({0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946})
  end

  describe "with the address guard on" do
    setup do
      previous = Application.get_env(:final_track, HTTP)

      resolver = fn
        ~c"public.example", :inet -> {:ok, [{93, 184, 216, 34}]}
        ~c"sneaky.example", :inet -> {:ok, [{10, 0, 0, 5}]}
        _, _ -> {:error, :nxdomain}
      end

      Application.put_env(:final_track, HTTP, guard_addresses: true, resolver: resolver)
      on_exit(fn -> Application.put_env(:final_track, HTTP, previous) end)
    end

    test "checks the scheme and where the host resolves" do
      assert {:ok, _uri, {93, 184, 216, 34}} = HTTP.check_url("https://public.example/users/x")
      assert {:error, :private_address} = HTTP.check_url("https://sneaky.example/inbox")
      assert {:error, :private_address} = HTTP.check_url("https://127.0.0.1/inbox")
      assert {:error, :private_address} = HTTP.check_url("https://[::1]/inbox")
      assert {:error, :unresolvable} = HTTP.check_url("https://nowhere.example/")
      assert {:error, :bad_scheme} = HTTP.check_url("http://public.example/")
      assert {:error, :bad_scheme} = HTTP.check_url("ftp://public.example/")
      assert {:error, :bad_url} = HTTP.check_url("not a url")
    end

    test "fetching a private address never leaves the building" do
      assert {:error, :private_address} = HTTP.fetch("https://sneaky.example/users/x")
    end
  end
end
