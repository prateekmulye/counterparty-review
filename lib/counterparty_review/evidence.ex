defmodule CounterpartyReview.Evidence do
  @moduledoc "Bounded public-identity inputs and source-grounded review guards."
  @countries [{"AT", "Austria"}, {"DE", "Germany"}, {"IE", "Ireland"}, {"NL", "Netherlands"}]
  @forms [
    {"AT", "AXSB", "Gesellschaft mit beschränkter Haftung"},
    {"AT", "EQOV", "Aktiengesellschaft"},
    {"DE", "2HBR", "Gesellschaft mit beschränkter Haftung"},
    {"DE", "6QQB", "Aktiengesellschaft"},
    {"DE", "SGST", "Europäische Aktiengesellschaft"},
    {"IE", "MNQ7", "Private Company Limited by Shares"},
    {"IE", "VYAX", "Public Limited Company"},
    {"NL", "54M6", "besloten vennootschap met beperkte aansprakelijkheid"},
    {"NL", "B5PM", "naamloze vennootschap"}
  ]
  @spec legal_forms() :: [map()]
  def legal_forms,
    do:
      Enum.map(@forms, fn {country, code, name} ->
        %{"country" => country, "code" => code, "name" => name}
      end)

  @spec supported_form?(term(), term()) :: boolean()
  def supported_form?(jurisdiction, code) when is_binary(jurisdiction),
    do:
      Enum.any?(@forms, fn {country, elf, _} ->
        country == String.slice(jurisdiction, 0, 2) and code == elf
      end)

  def supported_form?(_, _), do: false

  @policies [
    {"policy:identity",
     "GLEIF evidence identifies legal entities. A matching LEI does not establish creditworthiness, sanctions clearance, or KYC approval."},
    {"policy:conflicts",
     "Conflicting countries, registration identifiers, or LEIs require human review. Do not propose a match that contradicts an explicit identifier."},
    {"policy:human_review",
     "Every proposed identity match requires an explicit human decision. The system must not merge records or execute financial actions."}
  ]
  @spec countries() :: [{String.t(), String.t()}]
  def countries, do: @countries
  @spec input(map()) :: {:ok, map()} | {:error, [String.t()]}
  def input(params) when is_map(params) do
    if Enum.all?(Map.take(params, ["name", "country", "lei"]), fn {_, v} ->
         is_binary(v) and String.valid?(v)
       end) do
      name = String.trim(params["name"] || "")
      country = String.upcase(String.trim(params["country"] || ""))
      lei = String.upcase(String.trim(params["lei"] || ""))

      errors =
        []
        |> error(
          name == "" or byte_size(name) > 240 or String.match?(name, ~r/[\x00-\x1f\x7f]/u),
          "Enter a public company name of 1–240 UTF-8 bytes without control characters."
        )
        |> error(
          not Enum.any?(@countries, fn {code, _} -> code == country end),
          "Select a supported country of incorporation."
        )
        |> error(
          lei != "" and not valid_lei?(lei),
          "LEI must contain 20 characters and a valid checksum."
        )

      if errors == [],
        do:
          {:ok,
           %{
             "name" => name,
             "country" => country,
             "lei" => if(lei == "", do: nil, else: lei),
             "registration_id" => nil
           }},
        else: {:error, Enum.reverse(errors)}
    else
      {:error, ["Identity fields must contain text."]}
    end
  end

  def input(_), do: {:error, ["Invalid identity fields."]}
  defp error(errors, true, message), do: [message | errors]
  defp error(errors, false, _), do: errors

  @spec valid_lei?(term()) :: boolean()
  def valid_lei?(lei) when is_binary(lei) do
    if Regex.match?(~r/^[A-Z0-9]{18}[0-9]{2}$/, lei) do
      lei
      |> String.to_charlist()
      |> Enum.map_join(fn c ->
        if c in ?0..?9, do: <<c>>, else: Integer.to_string(c - ?A + 10)
      end)
      |> String.to_charlist()
      |> Enum.reduce(0, fn c, n -> rem(n * 10 + c - ?0, 97) end) == 1
    else
      false
    end
  end

  def valid_lei?(_), do: false

  @spec canonical(term()) :: binary()
  def canonical(value) when is_map(value),
    do:
      "{" <>
        (value
         |> Enum.sort_by(&elem(&1, 0))
         |> Enum.map_join(",", fn {k, v} -> Jason.encode!(k) <> ":" <> canonical(v) end)) <> "}"

  def canonical(value) when is_list(value),
    do: "[" <> Enum.map_join(value, ",", &canonical/1) <> "]"

  def canonical(value), do: Jason.encode!(value)
  @spec hash(term()) :: binary()
  def hash(value), do: :crypto.hash(:sha256, canonical(value)) |> Base.encode16(case: :lower)
  @spec byte_hash(binary()) :: binary()
  def byte_hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  @spec policies() :: [map()]
  def policies,
    do:
      Enum.map(@policies, fn {id, text} ->
        %{"evidence_id" => id, "text" => text, "content_sha256" => byte_hash(text)}
      end)

  @spec normalize(binary()) :: binary()
  def normalize(text),
    do:
      text
      |> String.normalize(:nfkc)
      |> :string.casefold()
      |> String.replace(~r/[^\p{L}\p{N}_]+/u, " ")
      |> String.trim()

  @spec review(map(), map()) :: map()
  def review(candidate, record) do
    reasons =
      []
      |> add(candidate["country"] != record["country"], "country_conflict")
      |> add(record["lei"] != nil and record["lei"] != candidate["lei"], "lei_conflict")
      |> add(candidate["entity_status"] != "ACTIVE", "inactive_entity")
      |> add(candidate["registration_status"] != "ISSUED", "noncurrent_registration")

    match =
      cond do
        record["lei"] == candidate["lei"] -> "exact_lei"
        normalize(record["name"]) == normalize(candidate["legal_name"]) -> "exact_legal_name"
        true -> "name_variant"
      end

    # A name mismatch with an explicit LEI is a visible conflict, not an inferred alias.
    reasons =
      add(
        reasons,
        record["lei"] != nil and normalize(record["name"]) != normalize(candidate["legal_name"]),
        "name_conflict"
      )

    candidate
    |> Map.put("acceptable", reasons == [])
    |> Map.put("reasons", [match | Enum.reverse(reasons)])
  end

  defp add(items, true, item), do: [item | items]
  defp add(items, false, _), do: items

  @spec facts(map(), map()) :: [binary()]
  def facts(record, candidate) do
    []
    |> add(record["lei"] != nil and record["lei"] == candidate["lei"], "exact_lei")
    |> add(record["lei"] != nil and record["lei"] != candidate["lei"], "lei_conflict")
    |> add(
      record["lei"] != nil and normalize(record["name"]) != normalize(candidate["legal_name"]),
      "name_conflict"
    )
    |> add(record["country"] == candidate["country"], "country_match")
    |> add(record["country"] != candidate["country"], "country_conflict")
    |> add(normalize(record["name"]) == normalize(candidate["legal_name"]), "exact_legal_name")
    |> add(normalize(record["name"]) != normalize(candidate["legal_name"]), "name_variant")
    |> add(candidate["entity_status"] != "ACTIVE", "inactive_entity")
    |> add(candidate["registration_status"] != "ISSUED", "noncurrent_registration")
    |> add(
      record["registration_id"] != nil and candidate["registration_id"] != nil and
        normalize(record["registration_id"] || "") ==
          normalize(candidate["registration_id"] || ""),
      "exact_registration_id"
    )
    |> add(
      record["registration_id"] != nil and candidate["registration_id"] != nil and
        normalize(record["registration_id"] || "") !=
          normalize(candidate["registration_id"] || ""),
      "registration_conflict"
    )
  end
end
