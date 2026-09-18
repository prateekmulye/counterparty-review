defmodule CounterpartyReview.ReviewWorker do
  @moduledoc "One durable queue and a fenced result boundary. No model-authorized writes."
  use Oban.Worker,
    queue: :reviews,
    max_attempts: 3,
    unique: [
      period: 300,
      keys: [:run_id, :operation],
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias CounterpartyReview.{Reviews, GLEIF, AgentPort}
  @impl true
  def timeout(_job), do: 90_000
  @impl true
  def perform(%Oban.Job{args: %{"run_id" => id, "operation" => operation}}) do
    case Reviews.internal_claim(id, operation) do
      {:ok, {run, lease}} ->
        started = System.monotonic_time()

        result =
          case operation do
            "retrieve" -> GLEIF.fetch(run.record)
            "analyze" -> AgentPort.run(Reviews.internal_envelope(run))
          end

        acknowledgement =
          case result do
            {:ok, value} ->
              Reviews.internal_finish(id, lease, operation, value)
              :ok

            {:error, code}
            when operation == "retrieve" and run.source_attempts < 3 and
                   code in [:source_unavailable, :source_timeout] ->
              case Reviews.internal_retry(id, lease, code) do
                {:ok, _} -> {:error, code}
                _ -> :ok
              end

            {:error, code} ->
              Reviews.internal_fail(id, lease, operation, code)
              :ok
          end

        :telemetry.execute(
          [:counterparty_review, :stage, :stop],
          %{duration: System.monotonic_time() - started},
          %{stage: operation, result: if(match?({:ok, _}, result), do: :ok, else: :error)}
        )

        acknowledgement

      {:error, {:leased, remaining}} ->
        {:snooze, remaining}

      {:error, _} ->
        :ok
    end
  end
end

defmodule CounterpartyReview.ExpireWorker do
  use Oban.Worker, queue: :maintenance, max_attempts: 3
  @impl true
  def perform(_job) do
    CounterpartyReview.Reviews.internal_purge_expired()
    :ok
  end
end
