defmodule CounterpartyReview.RuntimeConfigTest do
  use ExUnit.Case, async: false

  test "production config verifies TLS, requires stable secrets, and ignores proxy authority" do
    values = %{
      "PUBLIC_ORIGIN" => "https://counterparty.prateekmulye.dev",
      "SECRET_KEY_BASE" => String.duplicate("test-only", 8),
      "AI_PROVIDER" => "workers-ai",
      "DATABASE_URL" => "postgresql://example:example@db.example.invalid/reviews",
      "DATABASE_CA_FILE" => nil,
      "DB_NAME" => "counterparty_review_test",
      "PORT" => "9999"
    }

    previous = Map.new(values, fn {key, _} -> {key, System.get_env(key)} end)
    set_env(values)

    try do
      config = Config.Reader.read!("config/runtime.exs", env: :prod)
      app = Keyword.fetch!(config, :counterparty_review)
      endpoint = Keyword.fetch!(app, CounterpartyReviewWeb.Endpoint)
      assert endpoint[:server]
      assert endpoint[:http][:ip] == {127, 0, 0, 1}
      assert endpoint[:http][:port] == 8081
      assert endpoint[:url][:scheme] == "https"
      assert endpoint[:secret_key_base] == values["SECRET_KEY_BASE"]
      refute Keyword.has_key?(endpoint, :force_ssl)
      ssl = app[CounterpartyReview.Repo][:ssl]
      assert ssl[:verify] == :verify_peer
      assert ssl[:server_name_indication] == ~c"db.example.invalid"
      assert is_function(ssl[:customize_hostname_check][:match_fun], 2)

      for {key, bad} <- [
            {"SECRET_KEY_BASE", "short"},
            {"PUBLIC_ORIGIN", "https://attacker.invalid"},
            {"DATABASE_URL", values["DATABASE_URL"] <> "?ssl=false"},
            {"AI_PROVIDER", "local"}
          ] do
        System.put_env(key, bad)
        assert_raise RuntimeError, fn -> Config.Reader.read!("config/runtime.exs", env: :prod) end
        System.put_env(key, values[key])
      end

      System.put_env("DB_NAME", "production")

      assert_raise RuntimeError,
                   "Tests require the isolated counterparty_review_test database",
                   fn ->
                     Config.Reader.read!("config/runtime.exs", env: :test)
                   end
    after
      set_env(previous)
    end
  end

  defp set_env(values),
    do:
      Enum.each(values, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)

  test "packaged Python script matches reviewed source" do
    script = Path.join(:code.priv_dir(:counterparty_review), "agent/main.py")
    assert File.read!(script) == File.read!("agent/main.py")
  end

  test "security-patched Bandit remains pinned" do
    assert elem(Mix.Dep.Lock.read()[:bandit], 2) == "1.12.5"
  end

  test "maintenance history uses bounded Pruner" do
    config = Config.Reader.read!("config/config.exs", env: :prod)
    plugins = config[:counterparty_review][Oban][:plugins]
    opts = Keyword.fetch!(plugins, Oban.Plugins.Pruner)
    assert opts[:max_age] == 3_600
    assert opts[:limit] == 256
    assert opts[:interval] == 60_000
  end
end
