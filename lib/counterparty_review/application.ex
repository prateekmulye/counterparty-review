defmodule CounterpartyReview.Application do
  use Application
  @impl true
  def start(_type, _args) do
    CounterpartyReview.SafeLogging.attach()

    children = [
      CounterpartyReview.Repo,
      {Phoenix.PubSub, name: CounterpartyReview.PubSub},
      {Task.Supervisor, name: CounterpartyReview.FetchTasks, max_children: 2},
      {Oban, Application.fetch_env!(:counterparty_review, Oban)},
      CounterpartyReviewWeb.Endpoint
    ]

    result =
      Supervisor.start_link(children, strategy: :one_for_one, name: CounterpartyReview.Supervisor)

    if Application.get_env(:counterparty_review, :startup_cleanup, true) do
      # Migrations must precede serving; failure here must not hide unavailable storage.
      if match?({:ok, _}, result), do: CounterpartyReview.Reviews.internal_purge_expired()
    end

    result
  end
end
