defmodule CounterpartyReviewWeb.Router do
  use Phoenix.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug CounterpartyReviewWeb.Visitor
    plug :protect_from_forgery
  end

  scope "/", CounterpartyReviewWeb do
    pipe_through :browser
    get "/", ReviewController, :index
    post "/reviews", ReviewController, :create
    get "/reviews/:id", ReviewController, :show
    get "/reviews/:id/export", ReviewController, :export
    post "/reviews/:id/analyze", ReviewController, :analyze
    post "/reviews/:id/decide", ReviewController, :decide
    post "/reviews/:id/cancel", ReviewController, :cancel
    post "/reviews/:id/replay", ReviewController, :replay
    post "/reviews/:id/delete", ReviewController, :delete
  end
end
