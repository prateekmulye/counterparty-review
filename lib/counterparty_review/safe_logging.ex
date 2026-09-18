defmodule CounterpartyReview.SafeLogging do
  @moduledoc "Fixed-code request failure logs; exception terms may contain submitted input."
  require Logger

  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(
           "counterparty-request-errors",
           [:bandit, :request, :exception],
           &__MODULE__.request_exception/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @spec request_exception(list(), map(), map(), term()) :: :ok
  def request_exception(_event, _measurements, _metadata, _config) do
    Logger.warning("request_exception")
  end
end
