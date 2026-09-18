import Config
config :counterparty_review, ecto_repos: [CounterpartyReview.Repo]
config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, ["name", "country", "lei", "record", "_csrf_token"]
config :counterparty_review, CounterpartyReview.Repo, pool_size: 5, log: false

config :counterparty_review, Oban,
  repo: CounterpartyReview.Repo,
  queues: [reviews: 1, maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 3_600, interval: 60_000, limit: 256},
    {Oban.Plugins.Lifeline, rescue_after: 100_000, interval: 15_000},
    {Oban.Plugins.Cron, crontab: [{"* * * * *", CounterpartyReview.ExpireWorker}]}
  ]

config :counterparty_review, CounterpartyReviewWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: CounterpartyReviewWeb.ErrorHTML], layout: false],
  pubsub_server: CounterpartyReview.PubSub

config :logger, level: :warning
import_config "#{config_env()}.exs"
