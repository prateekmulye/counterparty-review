defmodule CounterpartyReviewWeb.ReviewHTML do
  use Phoenix.Component

  embed_templates "review_html/*"

  attr :title, :string, required: true
  slot :inner_block, required: true

  def shell(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@title} · Counterparty Review</title>
        <link rel="icon" href="/favicon.svg" type="image/svg+xml" />
        <link rel="stylesheet" href="/assets/review.css" />
      </head>
      <body>
        <a class="skip-link" href="#main">Skip to content</a>
        <header class="site-header wrap">
          <a href="/" class="brand" aria-label="Counterparty Review home"><span class="brand-mark" aria-hidden="true">cr.</span><span>Counterparty<br />Review</span></a>
          <nav aria-label="Main navigation"><a href="/">New review</a><a href="/#recent">Recent reviews</a><span class="edition">{if hosted?(), do: "Public edition", else: "Local edition"}</span></nav>
        </header>
        <main id="main" class="wrap" tabindex="-1">{render_slot(@inner_block)}</main>
        <footer class="site-footer wrap"><span>Public evidence. Human judgment.</span><span>Identity review only. No credit, sanctions or KYC clearance.</span></footer>
      </body>
    </html>
    """
  end

  attr :run, :map, required: true
  attr :csrf_token, :string, required: true

  def tokens(assigns) do
    ~H"""
    <input type="hidden" name="_csrf_token" value={@csrf_token} />
    <input type="hidden" name="revision" value={@run.revision} />
    <input type="hidden" name="evidence_hash" value={@run.evidence_hash} />
    """
  end

  defp hosted?, do: Application.get_env(:counterparty_review, :hosted, false)

  defp path(run, suffix \\ ""), do: "/reviews/#{run.id}#{suffix}"
  defp value(nil), do: "Not provided"
  defp value(""), do: "Not provided"
  defp value(value), do: value

  defp country(code),
    do:
      Enum.find_value(CounterpartyReview.Evidence.countries(), code, fn {c, name} ->
        if c == code, do: name
      end)

  defp date(nil), do: "Not provided"
  defp date(%DateTime{} = date), do: Calendar.strftime(date, "%d %b %Y, %H:%M UTC")

  defp date(date) when is_binary(date) do
    case DateTime.from_iso8601(date) do
      {:ok, parsed, _} -> date(parsed)
      _ -> value(date)
    end
  end

  defp pending?(run), do: run.state in ~w(queued retrieving reasoning)
  defp evidence?(run), do: run.evidence_hash != "" and map_size(run.source) > 0
  defp eligible(run), do: Enum.filter(run.candidates, & &1["acceptable"])

  defp state(state),
    do:
      Map.get(
        %{
          "queued" => "Waiting to start",
          "retrieving" => "Retrieving records",
          "reasoning" => "AI review in progress",
          "review_required" => "Review required",
          "accepted" => "Record accepted",
          "rejected" => "Review rejected",
          "cancelled" => "Run cancelled",
          "failed" => "Review failed",
          "expired" => "Review expired"
        },
        state,
        "Status unavailable"
      )

  defp state_detail("queued"), do: "Work is queued. Refresh to read its latest status."
  defp state_detail("retrieving"), do: "Retrieving public registry records from GLEIF."

  defp state_detail("reasoning"),
    do: "AI is reviewing saved evidence. Your decision is still required."

  defp state_detail("review_required"),
    do: "Inspect the evidence, then choose whether to record a decision."

  defp state_detail("accepted"),
    do: "Your decision is saved. This review can no longer be changed."

  defp state_detail("rejected"),
    do: "You rejected this review. This is not a finding about the company."

  defp state_detail("cancelled"),
    do:
      "No further result can change this review. Underlying model work may not stop immediately."

  defp state_detail("failed"),
    do: "This run could not complete. Start a new review to try a fresh lookup."

  defp state_detail(_), do: "Open a new review to continue."

  defp reason(code) do
    Map.get(
      %{
        "exact_lei" => "LEI matches the submitted identifier",
        "exact_registration_id" => "Registration identifier matches",
        "exact_legal_name" => "Normalized legal name matches",
        "name_variant" => "Name differs; inspect the legal name",
        "country_match" => "Jurisdiction country matches",
        "country_conflict" => "Jurisdiction country conflicts or is missing",
        "lei_conflict" => "LEI conflicts with the submitted identifier",
        "name_conflict" => "Legal name conflicts with the name supplied with the LEI",
        "registration_conflict" => "Registration identifiers conflict",
        "inactive_entity" => "Entity status does not meet this edition's ACTIVE rule",
        "noncurrent_registration" =>
          "Registration status does not meet this edition's ISSUED rule",
        "ambiguous_candidates" => "Multiple records remain plausible",
        "insufficient_evidence" => "Insufficient evidence to select a record",
        "policy_blocked" => "Review blocked by a policy check"
      },
      code,
      "Review condition: #{code}"
    )
  end

  defp field_error(errors, field) do
    Enum.find(errors, fn error ->
      case field do
        "name" -> String.starts_with?(error, "Enter a public company name")
        "country" -> String.starts_with?(error, "Select a supported country")
        "lei" -> String.starts_with?(error, "LEI must")
      end
    end)
  end

  defp error_target(error) do
    cond do
      String.starts_with?(error, "Enter a public company name") -> "name"
      String.starts_with?(error, "Select a supported country") -> "country"
      String.starts_with?(error, "LEI must") -> "lei"
      true -> "review-form"
    end
  end

  defp source_details(run, lei),
    do: Enum.find(run.source["last_updates"] || [], %{}, &(&1["lei"] == lei))

  defp candidate_name(run, lei),
    do:
      Enum.find_value(run.candidates, "Record unavailable", fn c ->
        if c["lei"] == lei, do: c["legal_name"]
      end)

  defp evidence_anchor("gleif:" <> lei), do: "#candidate-#{lei}"
  defp evidence_anchor(_), do: "#review-policy"
  defp citation_label(run, "gleif:" <> lei), do: candidate_name(run, lei)
  defp citation_label(_run, "policy:identity"), do: "Identity review policy"
  defp citation_label(_run, "policy:conflicts"), do: "Conflict review policy"
  defp citation_label(_run, "policy:human_review"), do: "Human decision policy"
  defp citation_label(_run, _), do: "Review policy"

  defp citations(run),
    do:
      (get_in(run.proposal || %{}, ["claims"]) || [])
      |> Enum.flat_map(&(&1["evidence_ids"] || []))
      |> Enum.uniq()

  defp ai_requested?(run),
    do: run.proposal != nil or Enum.any?(run.events, &(&1.kind == "analysis_requested"))

  defp ai_error(run),
    do: if(ai_requested?(run), do: run.ai_error || (run.proposal || %{})["error_code"])

  defp ai_title(run) do
    cond do
      ai_error(run) ->
        "AI review unavailable"

      run.state == "reasoning" or (run.state == "queued" and ai_requested?(run)) ->
        "AI review pending"

      run.proposal == nil and ai_requested?(run) ->
        "AI review did not complete"

      run.proposal == nil ->
        "AI review not requested"

      run.proposal["status"] == "proposed" ->
        "AI suggests a record"

      run.proposal["status"] == "conflict" ->
        "AI found a conflict"

      true ->
        "AI did not select a record"
    end
  end

  defp failure(code) do
    case String.downcase(to_string(code || "")) do
      "model_quota" ->
        "The shared AI allowance is exhausted. Manual evidence review remains available. Try AI after the next UTC daily reset."

      code
      when code in ["model_auth_failed", "model_configuration_error", "model_request_rejected"] ->
        "AI is unavailable because its service configuration could not be used. Manual review remains available."

      "model_timeout" ->
        "The model timed out. You can still review the registry evidence manually."

      "model_unavailable" ->
        "The model is unavailable. You can still review the registry evidence manually."

      "model_identity_mismatch" ->
        "The configured model could not be verified. Manual review remains available."

      "policy_blocked" ->
        "The model connection was denied by policy. Manual review remains available."

      "source_timeout" ->
        "The registry lookup timed out. No source evidence was saved."

      "source_unavailable" ->
        "The registry could not be reached. No source evidence was saved."

      "invalid_source" ->
        "The registry response could not be used. No source evidence was saved."

      "source_too_large" ->
        "The registry response exceeded this edition's limit. No source evidence was saved."

      _ ->
        "The result could not be used. Inspect any retained evidence and start a new review if needed."
    end
  end
end
