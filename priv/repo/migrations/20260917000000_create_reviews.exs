defmodule CounterpartyReview.Repo.Migrations.CreateReviews do
  use Ecto.Migration

  def up do
    create table(:review_runs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :record, :map, null: false
      add :input_hash, :text, null: false
      add :idempotency_key, :text, null: false
      add :state, :text, null: false
      add :revision, :integer, null: false, default: 1
      add :lease, :uuid
      add :lease_until, :utc_datetime_usec
      add :execution_deadline, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :evidence, :map
      add :evidence_hash, :text
      add :proposal, :map
      add :ai_error, :text
      add :decision, :map
      add :replay_of, :uuid
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:review_runs, [:idempotency_key])
    create index(:review_runs, [:expires_at])

    create constraint(:review_runs, :valid_state,
             check:
               "state IN ('queued','retrieving','reasoning','review_required','accepted','rejected','failed','cancelled','expired')"
           )

    create constraint(:review_runs, :valid_revision, check: "revision > 0")

    create table(:review_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, references(:review_runs, type: :uuid, on_delete: :delete_all), null: false
      add :sequence, :integer, null: false
      add :kind, :text, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:review_events, [:run_id, :sequence])
    Oban.Migration.up(version: 12)
  end

  def down do
    Oban.Migration.down(version: 1)
    drop table(:review_events)
    drop table(:review_runs)
  end
end
