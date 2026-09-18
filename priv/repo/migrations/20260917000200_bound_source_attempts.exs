defmodule CounterpartyReview.Repo.Migrations.BoundSourceAttempts do
  use Ecto.Migration

  def change do
    alter table(:review_runs) do
      add :source_attempts, :integer, default: 0, null: false
    end

    create constraint(:review_runs, :source_attempt_budget,
             check: "source_attempts >= 0 AND source_attempts <= 3"
           )
  end
end
