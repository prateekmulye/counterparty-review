defmodule CounterpartyReviewWeb.ReviewController do
  use Phoenix.Controller, formats: [:html], layouts: []
  alias CounterpartyReview.{Reviews, Evidence}

  def index(conn, _params), do: form(conn, %{}, [])

  def create(conn, params) do
    allowed = Map.take(params, ["name", "country", "lei"])

    case Reviews.create(conn.assigns.review_owner, allowed, params["idempotency_key"] || "") do
      {:ok, run} -> redirect(conn, to: "/reviews/#{run.id}")
      {:error, errors} when is_list(errors) -> conn |> put_status(422) |> form(allowed, errors)
      {:error, code} -> conn |> put_status(409) |> form(allowed, [message(code)])
    end
  end

  def show(conn, %{"id" => id}), do: display(conn, id, nil)

  def analyze(conn, params),
    do:
      action(conn, params, fn ->
        Reviews.analyze(
          conn.assigns.review_owner,
          params["id"],
          revision(params),
          params["evidence_hash"] || ""
        )
      end)

  def decide(conn, params),
    do:
      action(conn, params, fn ->
        Reviews.decide(
          conn.assigns.review_owner,
          params["id"],
          revision(params),
          params["evidence_hash"] || "",
          params["decision"],
          params["selected_lei"]
        )
      end)

  def cancel(conn, params),
    do:
      action(conn, params, fn ->
        Reviews.cancel(
          conn.assigns.review_owner,
          params["id"],
          revision(params),
          params["evidence_hash"] || ""
        )
      end)

  def replay(conn, %{"id" => id} = params),
    do: action(conn, params, fn -> Reviews.replay(conn.assigns.review_owner, id) end)

  def delete(conn, %{"id" => id}) do
    case Reviews.delete(conn.assigns.review_owner, id) do
      {:ok, :deleted} -> redirect(conn, to: "/")
      {:error, _} -> send_resp(conn, 404, "Review not found or already deleted.")
    end
  end

  def export(conn, %{"id" => id}) do
    case Reviews.export(conn.assigns.review_owner, id) do
      {:ok, packet} ->
        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=counterparty-review-#{id}.json"
        )
        |> send_resp(200, Jason.encode!(packet, pretty: true))

      {:error, _} ->
        send_resp(conn, 404, "Review not found or expired.")
    end
  end

  defp action(conn, params, fun) do
    case fun.() do
      {:ok, run} -> redirect(conn, to: "/reviews/#{run.id}")
      {:error, :not_found} -> send_resp(conn, 404, "Review not found or expired.")
      {:error, code} -> conn |> put_status(409) |> display(params["id"], message(code))
    end
  end

  defp display(conn, id, error) do
    case Reviews.view(conn.assigns.review_owner, id) do
      {:ok, run} ->
        render(conn, :show,
          run: run,
          csrf_token: Plug.CSRFProtection.get_csrf_token(),
          error: error
        )

      {:error, _} ->
        send_resp(conn, 404, "Review not found, deleted or expired.")
    end
  end

  defp form(conn, values, errors),
    do:
      render(conn, :index,
        runs: Reviews.list(conn.assigns.review_owner),
        values: sticky_values(values),
        errors: errors,
        countries: Evidence.countries(),
        idempotency_key: Ecto.UUID.generate(),
        csrf_token: Plug.CSRFProtection.get_csrf_token()
      )

  defp revision(%{"revision" => value}) when is_binary(value) and byte_size(value) <= 10 do
    case Integer.parse(value) do
      {number, ""} when number in 1..2_147_483_647 -> number
      _ -> -1
    end
  end

  defp revision(_), do: -1

  defp sticky_values(values) do
    Map.new([{"name", 240}, {"country", 2}, {"lei", 20}], fn {key, limit} ->
      value = values[key]

      safe =
        is_binary(value) and byte_size(value) <= limit and String.valid?(value) and
          not String.match?(value, ~r/[\x00-\x1f\x7f]/u)

      {key, if(safe, do: value, else: "")}
    end)
  end

  defp message(:retention_full),
    do:
      "Review storage is full. Delete an older review or wait for expired reviews to be removed."

  defp message(:analysis_limit),
    do:
      "This review has reached its three-request AI limit, including failed requests. Manual review remains available."

  defp message(:stale_review),
    do: "This review changed. Reload and inspect the current evidence before deciding."

  defp message(:identity_conflict),
    do:
      "This candidate conflicts with the submitted identity or its current status. Acceptance is blocked."

  defp message(:busy), do: "The review queue is full. Wait for current work to finish."

  defp message(:idempotency_conflict),
    do: "This submission key belongs to another input. Reload the form."

  defp message(:no_evidence), do: "No pinned evidence is available to replay. Start a new review."
  defp message(_), do: "This action is no longer available. Reload the review."
end
