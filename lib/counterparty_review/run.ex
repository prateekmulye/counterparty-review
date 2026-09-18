defmodule CounterpartyReview.Run do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @type t :: %__MODULE__{}
  schema "review_runs" do
    field :owner_hash, :string
    field :record, :map
    field :input_hash, :string
    field :idempotency_key, :string
    field :state, :string, default: "queued"
    field :revision, :integer, default: 1
    field :source_attempts, :integer, default: 0
    field :lease, :binary_id
    field :lease_until, :utc_datetime_usec
    field :execution_deadline, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :evidence, :map
    field :evidence_hash, :string
    field :proposal, :map
    field :ai_error, :string
    field :decision, :map
    field :replay_of, :binary_id
    timestamps(type: :utc_datetime_usec)
  end
end
