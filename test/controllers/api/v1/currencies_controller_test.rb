# frozen_string_literal: true

require "test_helper"

class Api::V1::CurrenciesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.update!(currency: "SGD", enabled_currencies: [ "USD" ])

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )
    Redis.new.del("api_rate_limit:#{@api_key.id}")
  end

  test "lists all currencies by default with family flags" do
    get api_v1_currencies_url, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    usd = response_body["currencies"].find { |currency| currency["iso_code"] == "USD" }
    sgd = response_body["currencies"].find { |currency| currency["iso_code"] == "SGD" }
    eur = response_body["currencies"].find { |currency| currency["iso_code"] == "EUR" }

    assert_operator response_body["currencies"].size, :>, 100
    assert_equal false, response_body.dig("meta", "enabled_only")
    assert_equal "SGD", response_body.dig("meta", "primary_currency")
    assert_equal @family.enabled_currency_codes, response_body.dig("meta", "enabled_currencies")

    assert_equal "United States Dollar", usd["name"]
    assert_equal "$", usd["symbol"]
    assert_equal 2, usd["default_precision"]
    assert_equal 0.01, usd["step"]
    assert_equal true, usd["enabled"]
    assert_equal false, usd["primary"]

    assert_equal true, sgd["enabled"]
    assert_equal true, sgd["primary"]
    assert_equal false, eur["enabled"]
  end

  test "lists enabled family currencies only" do
    get api_v1_currencies_url,
        params: { enabled_only: true },
        headers: api_headers(@api_key)

    assert_response :success
    codes = JSON.parse(response.body)["currencies"].map { |currency| currency["iso_code"] }

    assert_equal @family.enabled_currency_codes, codes
    assert_includes codes, "SGD"
    assert_includes codes, "USD"
    assert_not_includes codes, "EUR"
  end

  test "enabled-only list can include extra currencies for existing records" do
    get api_v1_currencies_url,
        params: { enabled_only: true, extra: [ "EUR" ] },
        headers: api_headers(@api_key)

    assert_response :success
    codes = JSON.parse(response.body)["currencies"].map { |currency| currency["iso_code"] }

    assert_includes codes, "SGD"
    assert_includes codes, "USD"
    assert_includes codes, "EUR"
  end

  test "filters currencies by query" do
    get api_v1_currencies_url,
        params: { q: "singapore" },
        headers: api_headers(@api_key)

    assert_response :success
    codes = JSON.parse(response.body)["currencies"].map { |currency| currency["iso_code"] }

    assert_includes codes, "SGD"
    assert_not_includes codes, "USD"
  end

  test "shows a currency" do
    get api_v1_currency_url("USD"), headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal "USD", response_body["iso_code"]
    assert_equal "United States Dollar", response_body["name"]
    assert_equal "$", response_body["symbol"]
    assert_equal "Cent", response_body["minor_unit"]
    assert_equal 100, response_body["minor_unit_conversion"]
    assert_equal 0.01, response_body["step"]
    assert_equal true, response_body["enabled"]
    assert_equal false, response_body["primary"]
  end

  test "returns not found for unknown currency" do
    get api_v1_currency_url("NOPE"), headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)

    assert_equal "not_found", response_body["error"]
    assert_equal "Currency not found", response_body["message"]
  end

  test "requires authentication" do
    get api_v1_currencies_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_currencies_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end
end
