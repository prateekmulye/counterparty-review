defmodule CounterpartyReview.Release do
  @moduledoc "Run migrations before starting the public endpoint."
  @spec migrate() :: :ok
  def migrate do
    Application.load(:counterparty_review)

    for repo <- Application.fetch_env!(:counterparty_review, :ecto_repos) do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    :ok
  end
end
