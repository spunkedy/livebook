defmodule Livebook.ZTA.GlobalTest do
  use ExUnit.Case, async: true

  test "make sure the application can start with a zta for custom" do
    System.put_env("TEST_LIVEBOOK_IDENTITY_PROVIDER", "custom:Livebook.ZTA.GlobalTest:123")
    provider = Livebook.Config.identity_provider!("TEST_LIVEBOOK_IDENTITY_PROVIDER")
    Application.put_env(:livebook, :identity_provider, provider)

    any_children =
      Livebook.Application.get_children()
      |> Enum.any?(fn
        {Livebook.ZTA.GlobalTest, _} -> true
        _ -> false
      end)

    assert any_children
  end

  test "make sure the application can start with a zta for a default" do
    System.put_env("TEST_LIVEBOOK_IDENTITY_PROVIDER", "cloudflare:123")
    provider = Livebook.Config.identity_provider!("TEST_LIVEBOOK_IDENTITY_PROVIDER")
    Application.put_env(:livebook, :identity_provider, provider)

    any_children =
      Livebook.Application.get_children()
      |> Enum.any?(fn
        {Livebook.ZTA.Cloudflare, _} -> true
        _ -> false
      end)

    assert any_children
  end
end
