defmodule CounterpartyReview.Event do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "review_events" do
    field :run_id, :binary_id
    field :sequence, :integer
    field :kind, :string
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
