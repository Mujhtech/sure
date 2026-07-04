# frozen_string_literal: true

require "test_helper"

class Api::V1::ExchangeRatesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
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

  test "returns rate for different currencies" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: Date.current)
                .returns(OpenStruct.new(rate: 1.2))

    get api_v1_exchange_rate_url,
        params: { from: "EUR", to: "USD" },
        headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal "EUR", response_body["from_currency"]
    assert_equal "USD", response_body["to_currency"]
    assert_equal Date.current.iso8601, response_body["date"]
    assert_equal 1.2, response_body["rate"]
    assert_equal false, response_body["same_currency"]
  end

  test "returns same currency rate without lookup" do
    ExchangeRate.expects(:find_or_fetch_rate).never

    get api_v1_exchange_rate_url,
        params: { from: "usd", to: "USD" },
        headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal "USD", response_body["from_currency"]
    assert_equal "USD", response_body["to_currency"]
    assert_equal 1.0, response_body["rate"]
    assert_equal true, response_body["same_currency"]
  end

  test "uses provided date" do
    date = Date.parse("2024-01-15")
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: date)
                .returns(1.25)

    get api_v1_exchange_rate_url,
        params: { from: "EUR", to: "USD", date: "2024-01-15" },
        headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert_equal "2024-01-15", response_body["date"]
    assert_equal 1.25, response_body["rate"]
  end

  test "returns bad request when currencies are missing" do
    get api_v1_exchange_rate_url,
        params: { from: "EUR" },
        headers: api_headers(@api_key)

    assert_response :bad_request
    response_body = JSON.parse(response.body)

    assert_equal "bad_request", response_body["error"]
    assert_equal "from and to currencies are required", response_body["message"]
  end

  test "returns bad request for invalid currency" do
    get api_v1_exchange_rate_url,
        params: { from: "NOPE", to: "USD" },
        headers: api_headers(@api_key)

    assert_response :bad_request
    response_body = JSON.parse(response.body)

    assert_equal "bad_request", response_body["error"]
    assert_equal "Invalid currency code", response_body["message"]
  end

  test "returns bad request for invalid date" do
    get api_v1_exchange_rate_url,
        params: { from: "EUR", to: "USD", date: "not-a-date" },
        headers: api_headers(@api_key)

    assert_response :bad_request
    response_body = JSON.parse(response.body)

    assert_equal "bad_request", response_body["error"]
    assert_equal "date must be an ISO 8601 date", response_body["message"]
  end

  test "returns not found when rate is unavailable" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: Date.current)
                .returns(nil)

    get api_v1_exchange_rate_url,
        params: { from: "EUR", to: "USD" },
        headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)

    assert_equal "not_found", response_body["error"]
    assert_equal "Exchange rate not found", response_body["message"]
  end

  test "returns exchange rate unavailable when lookup raises" do
    ExchangeRate.expects(:find_or_fetch_rate)
                .with(from: "EUR", to: "USD", date: Date.current)
                .raises(StandardError, "failed")

    get api_v1_exchange_rate_url,
        params: { from: "EUR", to: "USD" },
        headers: api_headers(@api_key)

    assert_response :bad_request
    response_body = JSON.parse(response.body)

    assert_equal "exchange_rate_unavailable", response_body["error"]
    assert_equal "Failed to fetch exchange rate", response_body["message"]
  end

  test "requires authentication" do
    get api_v1_exchange_rate_url, params: { from: "EUR", to: "USD" }

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

    get api_v1_exchange_rate_url,
        params: { from: "EUR", to: "USD" },
        headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end
end
