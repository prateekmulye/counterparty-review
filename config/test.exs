import Config
config :counterparty_review, CounterpartyReview.Repo, pool: Ecto.Adapters.SQL.Sandbox
config :counterparty_review, Oban, testing: :manual, queues: false, plugins: false
config :counterparty_review, CounterpartyReviewWeb.Endpoint, server: false
config :counterparty_review, startup_cleanup: false
