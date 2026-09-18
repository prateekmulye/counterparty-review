defmodule CounterpartyReview.MixProject do
  use Mix.Project

  def project do
    [
      app: :counterparty_review,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      compilers: [:agent_priv] ++ Mix.compilers(),
      deps: deps(),
      aliases: ["ecto.setup": ["ecto.create", "ecto.migrate"]]
    ]
  end

  def application,
    do: [mod: {CounterpartyReview.Application, []}, extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:phoenix, "== 1.8.9"},
      {:phoenix_html, "== 4.3.0"},
      {:phoenix_live_view, "== 1.1.33"},
      {:bandit, "== 1.12.5"},
      {:ecto_sql, "== 3.14.0"},
      {:ecto, "== 3.14.1"},
      {:postgrex, "== 0.22.4"},
      {:oban, "== 2.23.1"},
      {:jason, "== 1.4.5"},
      {:req, "== 0.6.1"}
    ]
  end
end

defmodule Mix.Tasks.Compile.AgentPriv do
  use Mix.Task.Compiler
  @impl true
  def run(_args) do
    source = File.read!("agent/main.py")
    target = "priv/agent/main.py"

    if File.read(target) == {:ok, source} do
      {:noop, []}
    else
      File.mkdir_p!("priv/agent")
      File.write!(target, source)
      {:ok, []}
    end
  end
end
