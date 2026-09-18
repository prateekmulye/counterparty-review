import Config

port =
  if config_env() == :prod, do: 8081, else: String.to_integer(System.get_env("PORT", "54185"))

unless port in 1024..65535, do: raise("PORT must be an unprivileged port")
config :counterparty_review, :port, port

if config_env() == :prod do
  origin = System.fetch_env!("PUBLIC_ORIGIN")
  uri = URI.parse(origin)

  unless uri.scheme == "https" and uri.host == "counterparty.prateekmulye.dev" and
           uri.port == 443 and uri.path in [nil, ""] and is_nil(uri.query) and
           is_nil(uri.fragment) and is_nil(uri.userinfo),
         do: raise("PUBLIC_ORIGIN must be https://counterparty.prateekmulye.dev")

  unless origin == "https://counterparty.prateekmulye.dev",
    do: raise("PUBLIC_ORIGIN must use its canonical form")

  unless System.get_env("AI_PROVIDER") == "workers-ai",
    do: raise("Production requires AI_PROVIDER=workers-ai")

  secret = System.fetch_env!("SECRET_KEY_BASE")
  if byte_size(secret) < 64, do: raise("SECRET_KEY_BASE must contain at least 64 bytes")
  config :counterparty_review, :public_origin, origin
  config :counterparty_review, :hosted, true

  config :counterparty_review, CounterpartyReviewWeb.Endpoint,
    server: true,
    url: [host: uri.host, port: 443, scheme: "https"],
    http: [
      ip: {127, 0, 0, 1},
      port: port,
      http_options: [
        log_exceptions_with_status_codes: [],
        log_protocol_errors: false,
        log_client_closures: false
      ]
    ],
    secret_key_base: secret

  database_url = System.fetch_env!("DATABASE_URL")
  db = URI.parse(database_url)

  unless db.scheme in ["postgres", "postgresql", "ecto"] and is_binary(db.host) and
           db.host != "" and is_binary(db.path) and db.path != "/" and
           is_nil(db.query) and is_nil(db.fragment),
         do: raise("DATABASE_URL must name a PostgreSQL host and database without query options")

  ca_options =
    case System.get_env("DATABASE_CA_FILE") do
      nil ->
        [cacerts: :public_key.cacerts_get()]

      path ->
        unless File.regular?(path),
          do: raise("DATABASE_CA_FILE must point to the provider CA bundle")

        [cacertfile: String.to_charlist(path)]
    end

  config :counterparty_review, CounterpartyReview.Repo,
    url: database_url,
    pool_size: 3,
    ssl:
      ca_options ++
        [
          verify: :verify_peer,
          server_name_indication: String.to_charlist(db.host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ]
else
  config :counterparty_review, :hosted, false
  config :counterparty_review, :public_origin, "http://127.0.0.1:#{port}"

  config :counterparty_review, CounterpartyReviewWeb.Endpoint,
    url: [host: "127.0.0.1", port: port, scheme: "http"],
    http: [
      ip: {127, 0, 0, 1},
      port: port,
      http_options: [
        log_exceptions_with_status_codes: [],
        log_protocol_errors: false,
        log_client_closures: false
      ]
    ],
    secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64))

  database = System.fetch_env!("DB_NAME")

  if config_env() == :test and database != "counterparty_review_test",
    do: raise("Tests require the isolated counterparty_review_test database")

  config :counterparty_review, CounterpartyReview.Repo,
    socket_dir: System.fetch_env!("DB_SOCKET_DIR"),
    port: String.to_integer(System.fetch_env!("DB_PORT")),
    username: System.fetch_env!("DB_USER"),
    database: database
end
