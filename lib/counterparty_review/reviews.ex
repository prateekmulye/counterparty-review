defmodule CounterpartyReview.Reviews do
  @moduledoc "Owner-scoped durable reviews. Database transactions own all decisions and job effects."
  import Ecto.Query
  alias CounterpartyReview.{Repo, Run, Event, Evidence, ReviewWorker}
  @terminal ~w(accepted rejected failed cancelled expired)
  @spec create(binary(), map(), binary()) :: {:ok, Run.t()} | {:error, term()}
  def create(owner, params, key), do: create_owned(owner, params, key, nil, nil)

  defp create_owned(owner, params, key, replay_of, pinned) do
    with {:ok, owner_hash} <- owner_hash(owner),
         {:ok, record} <- Evidence.input(params),
         {:ok, _} <- Ecto.UUID.cast(key) do
      hash = Evidence.hash(record)

      multi =
        Ecto.Multi.new()
        |> Ecto.Multi.run(:run, fn repo, _ ->
          # ponytail: serialize admission at fixed 128 retained / 20 active ceilings; partition only after measured demand.
          repo.query!("SELECT pg_advisory_xact_lock($1)", [54_185])

          case repo.get_by(Run, owner_hash: owner_hash, idempotency_key: key) do
            %Run{input_hash: ^hash} = existing ->
              {:ok, {:existing, existing}}

            %Run{} ->
              {:error, :idempotency_conflict}

            nil ->
              cond do
                Repo.aggregate(Run, :count) >= 128 or
                    Repo.aggregate(from(r in Run, where: r.owner_hash == ^owner_hash), :count) >=
                      16 ->
                  {:error, :retention_full}

                active_count() >= 20 ->
                  {:error, :busy}

                true ->
                  now = now()

                  run = %Run{
                    record: record,
                    owner_hash: owner_hash,
                    input_hash: hash,
                    idempotency_key: key,
                    state: if(pinned, do: "review_required", else: "queued"),
                    expires_at: DateTime.add(now, 86_400, :second),
                    execution_deadline: DateTime.add(now, 300, :second),
                    replay_of: replay_of,
                    evidence: pinned,
                    evidence_hash: if(pinned, do: Evidence.hash(pinned), else: nil)
                  }

                  case repo.insert(run) do
                    {:ok, run} ->
                      event!(run, if(pinned, do: "replayed", else: "submitted"))
                      {:ok, {:new, run}}

                    {:error, _} ->
                      {:error, :storage_failed}
                  end
              end
          end
        end)
        |> Ecto.Multi.run(:job, fn _, %{run: value} ->
          case value do
            {:new, %Run{state: "queued"} = run} ->
              Oban.insert(ReviewWorker.new(%{"run_id" => run.id, "operation" => "retrieve"}))

            _ ->
              {:ok, :not_required}
          end
        end)

      case Repo.transaction(multi) do
        {:ok, %{run: {_, run}}} -> {:ok, run}
        {:error, _, reason, _} -> {:error, reason}
      end
    else
      :error -> {:error, ["Invalid submission key. Reload the form."]}
      error -> error
    end
  end

  @spec list(binary()) :: [map()]
  def list(owner) do
    with {:ok, hash} <- owner_hash(owner) do
      Repo.all(
        from r in Run,
          where: r.owner_hash == ^hash and r.expires_at > ^now(),
          order_by: [desc: r.inserted_at],
          limit: 30
      )
      |> Enum.filter(&integrity?/1)
      |> Enum.map(&view/1)
    else
      _ -> []
    end
  end

  @spec get(binary(), binary()) :: {:ok, Run.t()} | {:error, atom()}
  def get(owner, id) do
    with {:ok, hash} <- owner_hash(owner),
         {:ok, id} <- Ecto.UUID.cast(id),
         %Run{} = run <- Repo.get_by(Run, id: id, owner_hash: hash) do
      cond do
        expired?(run) -> {:error, :not_found}
        not integrity?(run) -> {:error, :integrity_error}
        true -> {:ok, run}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @spec view(binary(), binary()) :: {:ok, map()} | {:error, atom()}
  def view(owner, id) do
    with {:ok, run} <- get(owner, id), do: {:ok, view(run)}
  end

  defp view(run) do
    evidence = run.evidence || %{}

    %{
      id: run.id,
      record: run.record,
      name: run.record["name"],
      country: run.record["country"],
      state: run.state,
      revision: run.revision,
      evidence_hash: run.evidence_hash || "",
      inserted_at: run.inserted_at,
      candidates: Enum.map(evidence["candidates"] || [], &Evidence.review(&1, run.record)),
      source: evidence["source"] || %{},
      proposal: run.proposal,
      ai_error: run.ai_error,
      decision: run.decision,
      expires_at: run.expires_at,
      replay_of: run.replay_of,
      events:
        Repo.all(from e in Event, where: e.run_id == ^run.id, order_by: e.sequence)
        |> Enum.map(
          &%{kind: &1.kind, sequence: &1.sequence, at: &1.inserted_at, metadata: &1.metadata}
        )
    }
  end

  @spec analyze(binary(), binary(), integer(), binary()) :: {:ok, Run.t()} | {:error, atom()}
  def analyze(owner, id, revision, hash) do
    mutate(
      {:owner, owner},
      id,
      fn run ->
        ensure_current!(run, revision, hash)

        unless run.state == "review_required" and run.evidence != nil,
          do: Repo.rollback(:invalid_state)

        requested =
          Repo.aggregate(
            from(e in Event, where: e.run_id == ^run.id and e.kind == "analysis_requested"),
            :count
          )

        if requested >= 3, do: Repo.rollback(:analysis_limit)

        if active_count() >= 20, do: Repo.rollback(:busy)

        updated =
          update!(
            run,
            %{
              state: "queued",
              proposal: nil,
              ai_error: nil,
              execution_deadline: DateTime.add(now(), 300, :second)
            },
            "analysis_requested"
          )

        {:ok, _} = Oban.insert(ReviewWorker.new(%{"run_id" => id, "operation" => "analyze"}))
        updated
      end,
      admission: true
    )
  end

  @spec decide(binary(), binary(), integer(), binary(), binary(), binary() | nil) ::
          {:ok, Run.t()} | {:error, atom()}
  def decide(owner, id, revision, hash, decision, lei) do
    mutate({:owner, owner}, id, fn run ->
      ensure_current!(run, revision, hash)

      unless run.state == "review_required" and decision in ["accept", "reject"],
        do: Repo.rollback(:invalid_state)

      if decision == "accept" do
        candidate = Enum.find(run.evidence["candidates"] || [], &(&1["lei"] == lei))

        unless candidate && Evidence.review(candidate, run.record)["acceptable"],
          do: Repo.rollback(:identity_conflict)
      end

      data = %{
        "action" => decision,
        "selected_lei" => if(decision == "accept", do: lei, else: nil),
        "at" => DateTime.to_iso8601(now()),
        "reviewed_revision" => revision,
        "evidence_hash" => hash
      }

      update!(
        run,
        %{
          state: if(decision == "accept", do: "accepted", else: "rejected"),
          decision: data,
          lease: nil,
          lease_until: nil
        },
        "human_decision"
      )
    end)
  end

  @spec cancel(binary(), binary(), integer(), binary()) :: {:ok, Run.t()} | {:error, atom()}
  def cancel(owner, id, revision, hash) do
    mutate({:owner, owner}, id, fn run ->
      ensure_current!(run, revision, hash)
      if run.state in @terminal, do: Repo.rollback(:invalid_state)
      cancel_jobs(id)
      update!(run, %{state: "cancelled", lease: nil, lease_until: nil}, "cancelled")
    end)
  end

  @spec replay(binary(), binary()) :: {:ok, Run.t()} | {:error, term()}
  def replay(owner, id) do
    mutate(
      {:owner, owner},
      id,
      fn run ->
        unless run.evidence, do: Repo.rollback(:no_evidence)
        params = Map.update!(run.record, "lei", &(&1 || ""))

        case create_owned(owner, params, Ecto.UUID.generate(), run.id, run.evidence) do
          {:ok, replay} -> replay
          {:error, code} -> Repo.rollback(code)
        end
      end,
      admission: true
    )
  end

  @spec delete(binary(), binary()) :: {:ok, :deleted} | {:error, atom()}
  def delete(owner, id), do: delete_scoped({:owner, owner}, id, false)

  defp internal_delete(id), do: delete_scoped(:internal, id, true)

  defp delete_scoped(scope, id, include_expired) do
    mutate(
      scope,
      id,
      fn run ->
        cancel_jobs(id)
        Repo.delete_all(from j in Oban.Job, where: fragment("?->>'run_id' = ?", j.args, ^id))
        Repo.delete!(run)
        :deleted
      end,
      include_expired: include_expired,
      skip_integrity: true
    )
  end

  @spec internal_claim(binary(), binary()) :: {:ok, {Run.t(), binary()}} | {:error, term()}
  def internal_claim(id, operation) do
    mutate(:internal, id, fn run ->
      if run.state in @terminal, do: Repo.rollback(:stale_job)
      if run.state == "review_required", do: Repo.rollback(:already_completed)
      unless operation in ["retrieve", "analyze"], do: Repo.rollback(:invalid_operation)
      if operation == "retrieve" and run.evidence != nil, do: Repo.rollback(:already_completed)
      if operation == "analyze" and run.evidence == nil, do: Repo.rollback(:no_evidence)

      if DateTime.compare(now(), run.execution_deadline) != :lt or
           (operation == "retrieve" and run.source_attempts >= 3 and is_nil(run.lease)) do
        code =
          if DateTime.compare(now(), run.execution_deadline) != :lt,
            do: :execution_deadline,
            else: :source_attempts_exhausted

        update!(
          run,
          %{
            state: if(run.evidence, do: "review_required", else: "failed"),
            ai_error: Atom.to_string(code),
            lease: nil,
            lease_until: nil
          },
          "execution_expired"
        )

        code
      else
        if run.lease_until && DateTime.compare(now(), run.lease_until) == :lt,
          do: Repo.rollback({:leased, max(DateTime.diff(run.lease_until, now(), :second) + 1, 1)})

        if operation == "retrieve" and run.source_attempts >= 3 do
          update!(
            run,
            %{
              state: "failed",
              ai_error: "source_attempts_exhausted",
              lease: nil,
              lease_until: nil
            },
            "source_budget_exhausted"
          )

          :source_attempts_exhausted
        else
          lease = Ecto.UUID.generate()

          run =
            update!(
              run,
              %{
                state: if(operation == "retrieve", do: "retrieving", else: "reasoning"),
                source_attempts:
                  run.source_attempts + if(operation == "retrieve", do: 1, else: 0),
                lease: lease,
                lease_until: DateTime.add(now(), 95, :second)
              },
              "work_started"
            )

          {run, lease}
        end
      end
    end)
    |> case do
      {:ok, :execution_deadline} -> {:error, :execution_deadline}
      {:ok, :source_attempts_exhausted} -> {:error, :source_attempts_exhausted}
      result -> result
    end
  end

  @spec internal_finish(binary(), binary(), binary(), map()) :: {:ok, Run.t()} | {:error, atom()}
  def internal_finish(id, lease, "retrieve", evidence) do
    mutate(:internal, id, fn run ->
      fence!(run, lease, "retrieving")
      unless run.evidence == nil, do: Repo.rollback(:immutable_evidence)

      update!(
        run,
        %{
          state: "review_required",
          evidence: evidence,
          evidence_hash: Evidence.hash(evidence),
          lease: nil,
          lease_until: nil
        },
        "evidence_ready"
      )
    end)
  end

  def internal_finish(id, lease, "analyze", result) do
    mutate(:internal, id, fn run ->
      fence!(run, lease, "reasoning")

      case CounterpartyReview.AgentPort.validate(result, internal_envelope(run)) do
        {:ok, safe} ->
          update!(
            run,
            %{
              state: "review_required",
              proposal: safe,
              ai_error: safe["error_code"],
              lease: nil,
              lease_until: nil
            },
            "analysis_finished"
          )

        {:error, _} ->
          update!(
            run,
            %{
              state: "review_required",
              proposal: nil,
              ai_error: "invalid_model_output",
              lease: nil,
              lease_until: nil
            },
            "analysis_failed"
          )
      end
    end)
  end

  @spec internal_fail(binary(), binary(), binary(), atom()) :: {:ok, Run.t()} | {:error, atom()}
  def internal_fail(id, lease, operation, code) do
    mutate(:internal, id, fn run ->
      fence!(run, lease, if(operation == "retrieve", do: "retrieving", else: "reasoning"))

      update!(
        run,
        %{
          state: if(run.evidence, do: "review_required", else: "failed"),
          ai_error: Atom.to_string(code),
          lease: nil,
          lease_until: nil
        },
        "work_failed"
      )
    end)
  end

  @spec internal_retry(binary(), binary(), atom()) :: {:ok, Run.t()} | {:error, atom()}
  def internal_retry(id, lease, code) do
    mutate(:internal, id, fn run ->
      fence!(run, lease, "retrieving")

      update!(
        run,
        %{state: "queued", ai_error: Atom.to_string(code), lease: nil, lease_until: nil},
        "retry_scheduled"
      )
    end)
  end

  @spec internal_envelope(Run.t()) :: map()
  def internal_envelope(run),
    do: %{
      "schema_version" => 1,
      "run_id" => run.id,
      "record" => run.record,
      "candidates" => run.evidence["candidates"],
      "policy_chunks" => run.evidence["policy_chunks"]
    }

  @spec export(binary(), binary()) :: {:ok, map()} | {:error, atom()}
  def export(owner, id) do
    with {:ok, run} <- get(owner, id) do
      requested_ai =
        Repo.exists?(
          from e in Event, where: e.run_id == ^run.id and e.kind == "analysis_requested"
        )

      model = get_in(run.proposal || %{}, ["model"]) || %{}
      invocations = model["invocations"]

      observed_model =
        cond do
          is_list(invocations) ->
            invocations
            |> Enum.filter(& &1["inference"])
            |> List.last()
            |> then(&if(&1, do: &1["observed_model"]))

          model["name"] == "qwen3.5:9b" and model["inference"] == true ->
            model["name"]

          true ->
            nil
        end

      packet = %{
        "schema_version" => 1,
        "run_id" => run.id,
        "revision" => run.revision,
        "source_attempts" => run.source_attempts,
        "state" => run.state,
        "record" => run.record,
        "requested_review_mode" => if(requested_ai, do: "ai_assisted", else: "deterministic"),
        "agent_provenance" => %{
          "requested_model_name" => model["name"],
          "observed_model_name" => observed_model,
          "model_digest" => nil,
          "prompt_version" => nil,
          "prompt_sha256" => nil,
          "unavailable_reason" =>
            if(get_in(run.proposal || %{}, ["model", "invocations"]),
              do:
                "Hosted invocation receipts below capture each prompt and provider observation; model weight digests are not supplied by the provider.",
              else:
                if(requested_ai,
                  do:
                    "Model digest and prompt version were not captured in this run's protocol; current source configuration is not historical run evidence.",
                  else: "AI was not requested for this run."
                )
            ),
          "invocations" => get_in(run.proposal || %{}, ["model", "invocations"]),
          "policy_chunks" => get_in(run.evidence || %{}, ["policy_chunks"])
        },
        "evidence" => run.evidence,
        "evidence_hash" => run.evidence_hash,
        "proposal" => run.proposal,
        "ai_error" => run.ai_error,
        "decision" => run.decision,
        "replay_of" => run.replay_of,
        "created_at" => DateTime.to_iso8601(run.inserted_at),
        "expires_at" => DateTime.to_iso8601(run.expires_at),
        "limits" => [
          "Public reference evidence; not identity certification, KYC, credit or sanctions clearance.",
          "No automatic merge or financial action.",
          "Human review; no measured model accuracy or operational benefit claimed."
        ]
      }

      {:ok, Map.put(packet, "packet_sha256", Evidence.hash(packet))}
    end
  end

  @spec internal_purge_expired() :: non_neg_integer()
  def internal_purge_expired do
    internal_close_overdue()

    Repo.all(from r in Run, where: r.expires_at <= ^now(), select: r.id)
    |> Enum.count(fn id -> match?({:ok, :deleted}, internal_delete(id)) end)
  end

  @spec internal_close_overdue() :: non_neg_integer()
  def internal_close_overdue do
    Repo.all(
      from r in Run,
        where:
          r.state in ["queued", "retrieving", "reasoning"] and r.execution_deadline <= ^now() and
            r.expires_at > ^now(),
        select: r.id
    )
    |> Enum.count(fn id ->
      case mutate(:internal, id, fn run ->
             if run.state not in ["queued", "retrieving", "reasoning"] or
                  DateTime.compare(now(), run.execution_deadline) == :lt,
                do: Repo.rollback(:already_completed)

             cancel_jobs(id)

             update!(
               run,
               %{
                 state: if(run.evidence, do: "review_required", else: "failed"),
                 ai_error: "execution_deadline",
                 lease: nil,
                 lease_until: nil
               },
               "execution_expired"
             )
           end) do
        {:ok, _} -> true
        _ -> false
      end
    end)
  end

  defp active_count,
    do:
      Repo.aggregate(
        from(r in Run,
          where: r.state in ["queued", "retrieving", "reasoning"] and r.expires_at > ^now()
        ),
        :count
      )

  defp mutate(scope, id, fun, opts \\ []) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn ->
        if opts[:admission], do: Repo.query!("SELECT pg_advisory_xact_lock($1)", [54_185])
        query = from r in Run, where: r.id == ^id, lock: "FOR UPDATE"

        query =
          case scope do
            :internal ->
              query

            {:owner, owner} ->
              case owner_hash(owner) do
                {:ok, hash} -> from r in query, where: r.owner_hash == ^hash
                _ -> Repo.rollback(:not_found)
              end
          end

        run = Repo.one(query)
        unless run, do: Repo.rollback(:not_found)
        if expired?(run) and opts[:include_expired] != true, do: Repo.rollback(:not_found)

        if opts[:skip_integrity] != true and not integrity?(run),
          do: Repo.rollback(:integrity_error)

        fun.(run)
      end)
    else
      _ -> {:error, :not_found}
    end
  end

  defp update!(run, attrs, kind) do
    run =
      run |> Ecto.Changeset.change(Map.put(attrs, :revision, run.revision + 1)) |> Repo.update!()

    event!(run, kind)
    run
  end

  defp event!(run, kind) do
    Repo.insert!(%Event{run_id: run.id, sequence: run.revision, kind: kind})
  end

  defp ensure_current!(run, revision, hash) do
    unless run.revision == revision and (run.evidence_hash || "") == hash,
      do: Repo.rollback(:stale_review)
  end

  defp fence!(run, lease, state) do
    unless run.lease == lease and run.state == state and
             DateTime.compare(now(), run.execution_deadline) == :lt,
           do: Repo.rollback(:stale_job)
  end

  defp cancel_jobs(id) do
    # Database state is the cancellation authority; executing children may finish but cannot publish.
    Repo.update_all(
      from(j in Oban.Job,
        where:
          fragment("?->>'run_id' = ?", j.args, ^id) and
            j.state in ["available", "scheduled", "retryable", "executing"]
      ),
      set: [state: "cancelled", cancelled_at: now()]
    )
  end

  defp expired?(run), do: DateTime.compare(now(), run.expires_at) != :lt

  defp integrity?(run),
    do:
      Evidence.hash(run.record) == run.input_hash and
        ((is_nil(run.evidence) and is_nil(run.evidence_hash)) or
           (is_map(run.evidence) and Evidence.hash(run.evidence) == run.evidence_hash))

  @spec owner_hash(binary()) :: {:ok, binary()} | {:error, :not_found}
  def owner_hash(owner) when is_binary(owner) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{43}\z/, owner),
      do:
        {:ok,
         :crypto.hash(:sha256, "counterparty-review:owner:v1:" <> owner)
         |> Base.encode16(case: :lower)},
      else: {:error, :not_found}
  end

  def owner_hash(_), do: {:error, :not_found}

  defp now, do: DateTime.utc_now()
end
