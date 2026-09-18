defmodule CounterpartyReview.Repo.Migrations.ScopeReviewOwners do
  use Ecto.Migration

  def up do
    alter table(:review_runs), do: add(:owner_hash, :text)

    create constraint(:review_runs, :valid_owner_hash,
             check: "owner_hash IS NULL OR owner_hash ~ '^[0-9a-f]{64}$'"
           )

    drop index(:review_runs, [:idempotency_key])
    create unique_index(:review_runs, [:owner_hash, :idempotency_key])
    create index(:review_runs, [:owner_hash, :inserted_at])
  end

  def down do
    raise "Owner isolation is not safely reversible after multiple visitors create reviews. Restore a pre-migration backup instead."
  end
end
