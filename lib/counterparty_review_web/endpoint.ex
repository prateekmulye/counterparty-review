defmodule CounterpartyReviewWeb.LocalBoundary do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _opts) do
    origin = Application.fetch_env!(:counterparty_review, :public_origin)
    uri = URI.parse(origin)
    host = uri.authority
    valid_host = get_req_header(conn, "host") == [host] and conn.host == uri.host
    valid_origin = conn.method in ["GET", "HEAD"] or get_req_header(conn, "origin") == [origin]

    if valid_host and valid_origin do
      conn
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; style-src 'self'; img-src 'self' data:; font-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'"
      )
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "same-origin")
      |> put_resp_header("cache-control", "no-store")
    else
      conn |> send_resp(403, "Canonical origin required.") |> halt()
    end
  end
end

defmodule CounterpartyReviewWeb.ErrorHTML do
  def render(_template, _assigns), do: "Request could not be completed. Reload the review."
end

defmodule CounterpartyReviewWeb.Health do
  import Plug.Conn
  def init(opts), do: opts

  def call(%Plug.Conn{method: method, request_path: "/health"} = conn, _)
      when method in ["GET", "HEAD"],
      do: conn |> put_resp_header("cache-control", "no-store") |> send_resp(200, "ok") |> halt()

  def call(conn, _), do: conn
end

defmodule CounterpartyReviewWeb.OwnerSession do
  @moduledoc "Host-only signed visitor ownership. Local HTTP has a distinct cookie name."
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    secure = Application.get_env(:counterparty_review, :hosted, false)
    key = if secure, do: "__Host-counterparty", else: "counterparty_local"
    cookies = get_req_header(conn, "cookie") |> Enum.flat_map(&String.split(&1, ";"))
    duplicates = Enum.count(cookies, &(String.trim(&1) |> String.starts_with?(key <> "=")))

    if duplicates > 1 do
      conn |> send_resp(400, "Invalid session.") |> halt()
    else
      opts =
        Plug.Session.init(
          store: :cookie,
          key: key,
          signing_salt: "counterparty-owner-v1",
          same_site: "Strict",
          http_only: true,
          secure: secure,
          path: "/",
          max_age: 86_400
        )

      Plug.Session.call(conn, opts)
    end
  end
end

defmodule CounterpartyReviewWeb.Visitor do
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    existing = get_session(conn, :owner)

    owner =
      case CounterpartyReview.Reviews.owner_hash(existing) do
        {:ok, _} -> existing
        _ -> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      end

    conn |> put_session(:owner, owner) |> assign(:review_owner, owner)
  end
end

defmodule CounterpartyReviewWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :counterparty_review
  plug CounterpartyReviewWeb.Health
  plug CounterpartyReviewWeb.LocalBoundary
  plug Plug.Static, at: "/", from: :counterparty_review, gzip: false, only: ~w(assets favicon.svg)

  plug Plug.Parsers,
    parsers: [:urlencoded],
    pass: [],
    length: 8_192,
    read_length: 8_193,
    read_timeout: 2_000

  plug CounterpartyReviewWeb.OwnerSession

  plug CounterpartyReviewWeb.Router
end
