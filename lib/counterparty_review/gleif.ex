defmodule CounterpartyReview.GLEIF do
  @moduledoc "One fixed-host, bounded public reference-data lookup per review."
  alias CounterpartyReview.Evidence
  @base "https://api.gleif.org/api/v1/lei-records"
  @limit 1_048_576
  @spec fetch(map()) :: {:ok, map()} | {:error, atom()}
  def fetch(record) do
    task = Task.Supervisor.async_nolink(CounterpartyReview.FetchTasks, fn -> request(record) end)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> {:error, :source_timeout}
    end
  end

  defp request(record) do
    url = if record["lei"], do: @base <> "/" <> record["lei"], else: @base

    params =
      if record["lei"],
        do: [],
        else: [{"filter[entity.legalName]", record["name"]}, {"page[size]", "6"}]

    started = System.monotonic_time(:millisecond)

    sink = fn {:data, chunk}, {request, response} ->
      if System.monotonic_time(:millisecond) - started > 5_000, do: throw(:source_timeout)
      encoding = Req.Response.get_header(response, "content-encoding")
      if encoding not in [[], ["identity"]], do: throw(:unsupported_encoding)
      body = (response.body || "") <> chunk
      if byte_size(body) > @limit, do: throw(:source_too_large)
      {:cont, {request, %{response | body: body}}}
    end

    case Req.get(url,
           params: params,
           redirect: false,
           retry: false,
           compressed: false,
           headers: [{"accept", "application/vnd.api+json"}, {"accept-encoding", "identity"}],
           receive_timeout: 5_000,
           connect_options: [timeout: 5_000],
           decode_body: false,
           into: sink
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        snapshot(body, record, DateTime.utc_now())

      {:ok, %{status: 404}} ->
        snapshot("{\"data\":[]}", record, DateTime.utc_now())

      {:ok, _} ->
        {:error, :source_unavailable}

      {:error, _} ->
        {:error, :source_unavailable}
    end
  rescue
    _ -> {:error, :source_unavailable}
  catch
    code when code in [:source_timeout, :source_too_large, :unsupported_encoding] ->
      {:error, code}
  end

  @spec snapshot(binary(), map(), DateTime.t()) :: {:ok, map()} | {:error, atom()}
  def snapshot(body, record, fetched_at) when byte_size(body) <= @limit do
    with {:ok, %{"data" => data} = decoded} <- Jason.decode(body),
         rows when is_list(rows) <- if(is_map(data), do: [data], else: data),
         true <- length(rows) <= 6 do
      normalized = Enum.map(rows, &candidate(&1, fetched_at)) |> Enum.filter(& &1)

      candidates =
        normalized
        |> Enum.take(5)
        |> Enum.sort_by(fn item ->
          {if(item["lei"] == record["lei"], do: 0, else: 1),
           if(Evidence.normalize(item["legal_name"]) == Evidence.normalize(record["name"]),
             do: 0,
             else: 1
           ), item["lei"]}
        end)

      source = %{
        "url" => @base,
        "retrieved_at" => DateTime.to_iso8601(fetched_at),
        "response_sha256" => Evidence.byte_hash(body),
        "snapshot_id" => Ecto.UUID.generate(),
        "matching_policy" => "public-identity-v1",
        "license" => "CC0",
        "license_url" => "https://www.gleif.org/en/meta/lei-data-terms-of-use",
        "country_field" => "entity.jurisdiction (first two ISO country characters)",
        "returned_count" => length(rows),
        "eligible_count" => length(normalized),
        "shown_count" => length(candidates),
        "unsupported_count" => length(rows) - length(normalized),
        "truncated" => length(rows) > 5 or not is_nil(get_in(decoded, ["links", "next"])),
        "filter" =>
          "Nine explicitly reviewed corporate legal forms in Austria, Germany, Ireland and the Netherlands. Other forms are excluded. Name search is bounded and is not exhaustive.",
        "supported_forms" => Evidence.legal_forms(),
        "legal_form_source" =>
          "GLEIF ELF v1.6 (2026-02-19), SHA256 c55edc421e49ce362457f772d6bfa41f5fc63ecaadea74db5735722625506ef4",
        "last_updates" =>
          rows
          |> Enum.filter(fn row -> Enum.any?(candidates, &(&1["lei"] == row["id"])) end)
          |> Enum.map(fn row ->
            %{
              "lei" => row["id"],
              "registration_last_update" =>
                get_in(row, ["attributes", "registration", "lastUpdateDate"]),
              "entity_jurisdiction" => get_in(row, ["attributes", "entity", "jurisdiction"]),
              "legal_form_code" => get_in(row, ["attributes", "entity", "legalForm", "id"])
            }
          end)
      }

      {:ok,
       %{"candidates" => candidates, "policy_chunks" => Evidence.policies(), "source" => source}}
    else
      _ -> {:error, :invalid_source}
    end
  end

  def snapshot(_, _, _), do: {:error, :source_too_large}

  defp candidate(
         %{"id" => lei, "attributes" => %{"entity" => entity, "registration" => registration}},
         fetched_at
       ) do
    name = get_in(entity, ["legalName", "name"])
    jurisdiction = entity["jurisdiction"]
    form = get_in(entity, ["legalForm", "id"])
    registration_id = entity["registeredAs"]

    if Evidence.valid_lei?(lei) and entity["category"] == "GENERAL" and
         Evidence.supported_form?(jurisdiction, form) and
         is_binary(name) and byte_size(name) in 1..240 and is_binary(jurisdiction) and
         Regex.match?(~r/^[A-Z]{2}(?:-[A-Z0-9]{1,3})?$/, jurisdiction) and
         (is_nil(registration_id) or
            (is_binary(registration_id) and byte_size(registration_id) <= 80)) and
         entity["status"] in ["ACTIVE", "INACTIVE", "NULL"] and is_binary(registration["status"]) and
         byte_size(registration["status"]) <= 40 do
      fields = %{
        "lei" => lei,
        "legal_name" => name,
        "country" => String.slice(jurisdiction, 0, 2),
        "registration_id" => registration_id,
        "entity_status" => entity["status"],
        "registration_status" => registration["status"]
      }

      Map.merge(fields, %{
        "evidence_id" => "gleif:" <> lei,
        "source_url" => @base <> "/" <> lei,
        "retrieved_at" => DateTime.to_iso8601(fetched_at),
        "content_sha256" => Evidence.hash(fields)
      })
    end
  end

  defp candidate(_, _), do: nil
end
