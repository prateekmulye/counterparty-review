defmodule CounterpartyReview.AgentPort do
  @moduledoc "One isolated Python invocation; no inherited secrets, shell, writes or approval authority."
  alias CounterpartyReview.Evidence

  @keys ~w(schema_version run_id status selected_lei reason_codes claims model usage error_code trace)
  @reasons ~w(exact_lei exact_registration_id exact_legal_name name_variant name_conflict country_match country_conflict lei_conflict registration_conflict inactive_entity noncurrent_registration ambiguous_candidates insufficient_evidence model_unavailable model_timeout invalid_model_output policy_blocked)
  @errors ~w(MODEL_UNAVAILABLE MODEL_TIMEOUT MODEL_IDENTITY_MISMATCH INVALID_MODEL_OUTPUT INVALID_INPUT POLICY_BLOCKED MODEL_QUOTA MODEL_AUTH_FAILED MODEL_CONFIGURATION_ERROR MODEL_REQUEST_REJECTED)
  @hosted_model "@cf/qwen/qwen3-30b-a3b-fp8"
  @spec run(map()) :: {:ok, map()} | {:error, atom()}
  def run(envelope) do
    encoded = Jason.encode!(envelope) <> "\n"

    if byte_size(encoded) > 262_144 do
      {:error, :agent_input_too_large}
    else
      python = System.find_executable("python3")
      script = Path.join(:code.priv_dir(:counterparty_review), "agent/main.py")

      if python && File.regular?(script) do
        # Ignore inherited Python paths/startup files and remove every inherited environment value.
        env =
          Enum.map(System.get_env(), fn {key, value} ->
            allowed = key in ~w(AI_PROVIDER AI_GATEWAY_URL AI_GATEWAY_SECRET)
            {String.to_charlist(key), if(allowed, do: String.to_charlist(value), else: false)}
          end)

        port =
          Port.open({:spawn_executable, String.to_charlist(python)}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            :hide,
            args: [~c"-I", ~c"-B", ~c"-u", String.to_charlist(script)],
            env: env
          ])

        try do
          Port.command(port, encoded)

          with {:ok, bytes} <- collect(port, "", System.monotonic_time(:millisecond) + 70_000),
               true <-
                 String.ends_with?(bytes, "\n") and
                   length(String.split(String.trim(bytes), "\n")) == 1,
               {:ok, result} <- Jason.decode(bytes),
               {:ok, safe} <- validate(result, envelope) do
            {:ok, safe}
          else
            {:error, code} when is_atom(code) -> {:error, code}
            _ -> {:error, :invalid_model_output}
          end
        after
          terminate_owned(port)
        end
      else
        {:error, :model_unavailable}
      end
    end
  rescue
    _ -> {:error, :model_unavailable}
  end

  defp collect(port, bytes, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        if byte_size(bytes) + byte_size(chunk) > 32_768,
          do: {:error, :agent_output_too_large},
          else: collect(port, bytes <> chunk, deadline)

      {^port, {:exit_status, 0}} ->
        {:ok, bytes}

      {^port, {:exit_status, _}} ->
        {:error, :model_unavailable}
    after
      remaining -> {:error, :model_timeout}
    end
  end

  defp terminate_owned(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        # Only the still-open port's own process; never the shared model server.
        System.cmd("/bin/kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
        if Port.info(port), do: Port.close(port)

      nil ->
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  @spec validate(term(), map()) :: {:ok, map()} | {:error, atom()}
  def validate(result, envelope) do
    candidates = envelope["candidates"]
    policies = envelope["policy_chunks"]
    known = MapSet.new(Enum.map(candidates ++ policies, & &1["evidence_id"]))

    selected =
      if is_map(result), do: Enum.find(candidates, &(&1["lei"] == result["selected_lei"]))

    valid =
      exact_keys?(result, @keys) and result["schema_version"] == 1 and
        result["run_id"] == envelope["run_id"] and
        result["status"] in ["proposed", "conflict", "abstain"] and
        valid_model?(result["model"]) and
        exact_keys?(result["usage"], ~w(input_tokens output_tokens wall_ms)) and
        Enum.all?(
          ~w(input_tokens output_tokens),
          &(is_nil(result["usage"][&1]) or nonnegative?(result["usage"][&1]))
        ) and nonnegative?(result["usage"]["wall_ms"]) and
        is_list(result["reason_codes"]) and length(result["reason_codes"]) in 1..8 and
        Enum.all?(result["reason_codes"], &(&1 in @reasons)) and
        is_list(result["claims"]) and length(result["claims"]) <= 8 and
        Enum.all?(result["claims"], &valid_claim?(&1, candidates, policies)) and
        is_list(result["trace"]) and length(result["trace"]) <= 2 and
        valid_trace?(result["trace"], known) and
        (is_nil(result["error_code"]) or result["error_code"] in @errors)

    valid =
      valid and
        if result["status"] == "proposed" do
          selected != nil and Evidence.review(selected, envelope["record"])["acceptable"] and
            result["model"]["inference"] and is_nil(result["error_code"]) and
            result["claims"] != [] and unambiguous?(selected, envelope) and
            Enum.any?(
              result["reason_codes"],
              &(&1 in ~w(exact_lei exact_registration_id exact_legal_name name_variant))
            ) and
            Enum.any?(
              result["trace"],
              &(&1["tool"] == "inspect_candidate" and &1["evidence_id"] == selected["evidence_id"])
            ) and
            Enum.any?(
              result["trace"],
              &(&1["tool"] == "retrieve_policy" and &1["evidence_id"] == "policy:identity")
            )
        else
          is_nil(result["selected_lei"])
        end

    valid =
      valid and
        (result["model"]["inference"] or
           (result["status"] == "abstain" and result["error_code"] in @errors))

    valid = valid and semantic_result?(result, envelope)

    if valid, do: {:ok, result}, else: {:error, :invalid_model_output}
  rescue
    _ -> {:error, :invalid_model_output}
  end

  defp semantic_result?(%{"error_code" => code} = result, _) when not is_nil(code) do
    expected =
      case code do
        "MODEL_UNAVAILABLE" ->
          "model_unavailable"

        "MODEL_IDENTITY_MISMATCH" ->
          "model_unavailable"

        code
        when code in ~w(MODEL_QUOTA MODEL_AUTH_FAILED MODEL_CONFIGURATION_ERROR MODEL_REQUEST_REJECTED) ->
          "model_unavailable"

        "MODEL_TIMEOUT" ->
          "model_timeout"

        "POLICY_BLOCKED" ->
          "policy_blocked"

        _ ->
          "invalid_model_output"
      end

    result["status"] == "abstain" and is_nil(result["selected_lei"]) and result["claims"] == [] and
      result["reason_codes"] == [expected]
  end

  defp semantic_result?(result, envelope) do
    cited_ids = result["claims"] |> Enum.flat_map(& &1["evidence_ids"]) |> MapSet.new()
    cited = Enum.filter(envelope["candidates"], &MapSet.member?(cited_ids, &1["evidence_id"]))
    facts = cited |> Enum.flat_map(&Evidence.facts(envelope["record"], &1)) |> MapSet.new()

    eligible =
      Enum.filter(envelope["candidates"], &Evidence.review(&1, envelope["record"])["acceptable"])

    Enum.all?(result["reason_codes"], fn
      "insufficient_evidence" -> result["status"] == "abstain"
      "ambiguous_candidates" -> result["status"] == "abstain" and length(eligible) > 1
      reason -> MapSet.member?(facts, reason)
    end) and
      (result["status"] != "proposed" or Enum.all?(cited, &(&1["lei"] == result["selected_lei"]))) and
      (result["status"] != "conflict" or
         Enum.any?(
           result["reason_codes"],
           &(&1 in ~w(lei_conflict country_conflict registration_conflict name_conflict))
         ))
  end

  defp unambiguous?(candidate, envelope) do
    same_names =
      Enum.filter(envelope["candidates"], fn other ->
        other["country"] == candidate["country"] and
          Evidence.normalize(other["legal_name"]) == Evidence.normalize(candidate["legal_name"])
      end)

    length(same_names) == 1 or
      Enum.any?(
        Evidence.facts(envelope["record"], candidate),
        &(&1 in ~w(exact_lei exact_registration_id))
      )
  end

  defp valid_claim?(claim, candidates, policies) do
    exact_keys?(claim, ~w(text evidence_ids)) and is_binary(claim["text"]) and
      byte_size(claim["text"]) <= 300 and
      Enum.any?(candidates ++ policies, fn item ->
        claim["evidence_ids"] == [item["evidence_id"]] and claim["text"] in claim_texts(item)
      end)
  end

  defp claim_texts(%{"text" => text}), do: [text]

  defp claim_texts(candidate),
    do: [
      "GLEIF legal name: " <> candidate["legal_name"],
      "GLEIF LEI: " <> candidate["lei"],
      "Jurisdiction country: " <> candidate["country"],
      "GLEIF entity status: " <> candidate["entity_status"],
      "GLEIF registration status: " <>
        candidate["registration_status"] <>
        ". Registration status is distinct from entity status."
    ]

  defp valid_trace?(trace, known) do
    Enum.with_index(trace, 1)
    |> Enum.all?(fn {step, index} ->
      exact_keys?(step, ~w(step tool evidence_id)) and step["step"] == index and
        step["tool"] in ["inspect_candidate", "retrieve_policy"] and
        MapSet.member?(known, step["evidence_id"]) and
        String.starts_with?(
          step["evidence_id"],
          if(step["tool"] == "inspect_candidate", do: "gleif:", else: "policy:")
        )
    end) and length(Enum.uniq_by(trace, &{&1["tool"], &1["evidence_id"]})) == length(trace)
  end

  defp valid_model?(model) do
    is_map(model) and
      (exact_keys?(model, ~w(name inference)) or
         exact_keys?(model, ~w(name inference invocations))) and
      model["name"] in ["qwen3.5:9b", @hosted_model] and is_boolean(model["inference"]) and
      case Map.fetch(model, "invocations") do
        :error ->
          true

        {:ok, receipts} ->
          model["name"] == @hosted_model and is_list(receipts) and length(receipts) <= 3 and
            Enum.all?(receipts, &valid_invocation?/1) and
            length(Enum.uniq_by(receipts, & &1["request_id"])) == length(receipts) and
            (not model["inference"] or Enum.any?(receipts, & &1["inference"]))
      end
  end

  defp valid_invocation?(receipt) do
    exact_keys?(
      receipt,
      ~w(requested_model observed_model completion_id provider_request_id usage finish_reason elapsed_ms inference request_id gateway_contract_version prompt_version prompt_sha256)
    ) and
      receipt["requested_model"] == @hosted_model and
      receipt["observed_model"] in [nil, @hosted_model] and
      is_boolean(receipt["inference"]) and receipt["gateway_contract_version"] == 1 and
      match?({:ok, _}, Ecto.UUID.cast(receipt["request_id"])) and
      receipt["prompt_version"] in ~w(counterparty.step.v1 counterparty.proposal.v1) and
      is_binary(receipt["prompt_sha256"]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, receipt["prompt_sha256"]) and
      is_integer(receipt["elapsed_ms"]) and receipt["elapsed_ms"] in 0..120_000 and
      Enum.all?(~w(completion_id provider_request_id finish_reason), fn key ->
        is_nil(receipt[key]) or
          (is_binary(receipt[key]) and
             Regex.match?(~r/\A[A-Za-z0-9_@.\/-]{1,200}\z/, receipt[key]))
      end) and valid_provider_usage?(receipt["usage"])
  end

  defp valid_provider_usage?(nil), do: true

  defp valid_provider_usage?(usage) do
    exact_keys?(usage, ~w(prompt_tokens completion_tokens total_tokens neurons)) and
      Enum.all?(~w(prompt_tokens completion_tokens total_tokens), fn key ->
        is_nil(usage[key]) or (is_integer(usage[key]) and usage[key] in 0..100_000)
      end) and
      (is_nil(usage["neurons"]) or
         (is_number(usage["neurons"]) and usage["neurons"] >= 0 and usage["neurons"] <= 10_000))
  end

  defp exact_keys?(map, keys), do: is_map(map) and Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp nonnegative?(value), do: is_integer(value) and value >= 0
end
