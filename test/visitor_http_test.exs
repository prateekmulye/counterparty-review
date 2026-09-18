defmodule CounterpartyReview.VisitorHTTPTest do
  use ExUnit.Case, async: false
  alias CounterpartyReview.{Repo, Run, Event}
  alias CounterpartyReviewWeb.Endpoint
  @origin "https://counterparty.prateekmulye.dev"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    Repo.delete_all(Oban.Job)
    Repo.delete_all(Event)
    Repo.delete_all(Run)
    origin = Application.fetch_env!(:counterparty_review, :public_origin)
    hosted = Application.fetch_env!(:counterparty_review, :hosted)
    Application.put_env(:counterparty_review, :public_origin, @origin)
    Application.put_env(:counterparty_review, :hosted, true)

    on_exit(fn ->
      Application.put_env(:counterparty_review, :public_origin, origin)
      Application.put_env(:counterparty_review, :hosted, hosted)
      Ecto.Adapters.SQL.Sandbox.checkin(Repo)
    end)

    :ok
  end

  defp request(method, path, cookie \\ nil, params \\ %{}) do
    Plug.CSRFProtection.delete_csrf_token()

    conn =
      Plug.Test.conn(method, @origin <> path, params)
      |> host_header("counterparty.prateekmulye.dev")

    conn = if cookie, do: Plug.Conn.put_req_header(conn, "cookie", cookie), else: conn
    conn = if method == :post, do: Plug.Conn.put_req_header(conn, "origin", @origin), else: conn
    Endpoint.call(conn, Endpoint.init([]))
  end

  defp host_header(conn, host), do: %{conn | req_headers: [{"host", host} | conn.req_headers]}

  defp cookie(conn) do
    conn |> Plug.Conn.get_resp_header("set-cookie") |> hd() |> String.split(";") |> hd()
  end

  defp token(conn),
    do: Regex.run(~r/name="_csrf_token" value="([^"]+)"/, conn.resp_body) |> Enum.at(1)

  test "two signed cookie jars cannot list, read, change, replay, export or delete another review" do
    first = request(:get, "/")
    second = request(:get, "/")
    cookie_a = cookie(first)
    cookie_b = cookie(second)
    refute cookie_a == cookie_b
    [header] = Plug.Conn.get_resp_header(first, "set-cookie")

    for flag <- ["__Host-counterparty=", "secure", "HttpOnly", "SameSite=Strict", "path=/"] do
      assert String.contains?(String.downcase(header), String.downcase(flag))
    end

    refute String.contains?(String.downcase(header), "domain=")

    created =
      request(:post, "/reviews", cookie_a, %{
        "_csrf_token" => token(first),
        "idempotency_key" => Ecto.UUID.generate(),
        "name" => "Private Test Aktiengesellschaft",
        "country" => "DE",
        "lei" => ""
      })

    assert created.status == 302
    [path] = Plug.Conn.get_resp_header(created, "location")
    assert request(:get, path, cookie_a).status == 200
    assert request(:get, path, cookie_b).status == 404
    assert request(:get, path <> "/export", cookie_b).status == 404
    assert request(:get, path <> "/export", cookie_a).status == 200
    other_list = request(:get, "/", cookie_b)
    refute other_list.resp_body =~ "Private Test Aktiengesellschaft"

    for action <- ["analyze", "decide", "cancel", "replay", "delete"] do
      result =
        request(:post, path <> "/" <> action, cookie_b, %{
          "_csrf_token" => token(other_list),
          "revision" => "1",
          "evidence_hash" => "",
          "decision" => "reject"
        })

      assert result.status == 404, action
    end

    assert Repo.aggregate(Run, :count) == 1
    assert Repo.one!(Run).revision == 1
    assert request(:get, path, nil).status == 404
    assert request(:get, path, cookie_a <> "; " <> cookie_a).status == 400
  end

  test "health has no owner or database action and forwarding headers cannot change authority" do
    health = request(:get, "/health")
    assert health.status == 200 and health.resp_body == "ok"
    assert Plug.Conn.get_resp_header(health, "set-cookie") == []
    assert Repo.aggregate(Run, :count) == 0

    conn =
      Plug.Test.conn(:get, "http://attacker.invalid/")
      |> host_header("attacker.invalid")
      |> Plug.Conn.put_req_header("x-forwarded-host", "counterparty.prateekmulye.dev")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")

    assert Endpoint.call(conn, Endpoint.init([])).status == 403

    conn =
      Plug.Test.conn(:post, @origin <> "/reviews")
      |> host_header("counterparty.prateekmulye.dev")
      |> Plug.Conn.put_req_header("origin", "https://prateekmulye.dev")

    assert Endpoint.call(conn, Endpoint.init([])).status == 403
  end

  test "malformed revision and sticky values never raise or expose input through logs" do
    page = request(:get, "/")
    jar = cookie(page)
    csrf = token(page)

    created =
      request(:post, "/reviews", jar, %{
        "_csrf_token" => csrf,
        "idempotency_key" => Ecto.UUID.generate(),
        "name" => "Example Aktiengesellschaft",
        "country" => "DE",
        "lei" => ""
      })

    [path] = Plug.Conn.get_resp_header(created, "location")
    canary = "PRIVATE_INPUT_CANARY_7491"

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        for revision <- [[canary], %{"private" => canary}, String.duplicate("9", 400), nil] do
          for action <- ["analyze", "decide", "cancel"] do
            result =
              request(:post, path <> "/" <> action, jar, %{
                "_csrf_token" => csrf,
                "revision" => revision,
                "evidence_hash" => "",
                "decision" => "reject"
              })

            assert result.status == 409
          end
        end

        for key <- ["name", "country", "lei"],
            value <- [[canary], %{"private" => canary}, String.duplicate(canary, 50), <<255>>] do
          result =
            request(
              :post,
              "/reviews",
              jar,
              Map.put(
                %{
                  "_csrf_token" => csrf,
                  "idempotency_key" => Ecto.UUID.generate(),
                  "name" => "Example Aktiengesellschaft",
                  "country" => "DE",
                  "lei" => ""
                },
                key,
                value
              )
            )

          assert result.status == 422
          refute result.resp_body =~ canary
        end
      end)

    refute logs =~ canary
    assert Repo.one!(Run).revision == 1
  end

  test "unexpected transport exceptions use fixed code only and raw exception logging is disabled" do
    canary = "PRIVATE_EXCEPTION_CANARY_7491"
    opts = Application.fetch_env!(:counterparty_review, Endpoint)[:http][:http_options]

    logs =
      ExUnit.CaptureLog.capture_log(fn ->
        server =
          start_supervised!(
            {Bandit,
             plug: CounterpartyReview.ExceptionCanaryPlug,
             ip: {127, 0, 0, 1},
             port: 0,
             http_options: opts}
          )

        {:ok, {_, port}} = ThousandIsland.listener_info(server)
        {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)

        try do
          :ok =
            :gen_tcp.send(
              socket,
              "GET /?#{canary} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
            )

          assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
          assert response =~ "500 Internal Server Error"
          refute response =~ canary
        after
          :gen_tcp.close(socket)
        end
      end)

    assert logs =~ "request_exception"
    refute logs =~ canary
    assert opts[:log_exceptions_with_status_codes] == []
    assert opts[:log_protocol_errors] == false
  end
end

defmodule CounterpartyReview.ExceptionCanaryPlug do
  def init(opts), do: opts
  def call(conn, _opts), do: raise("untrusted #{conn.query_string}")
end
