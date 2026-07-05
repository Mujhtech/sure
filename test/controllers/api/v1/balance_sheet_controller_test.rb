# frozen_string_literal: true

require "test_helper"

class Api::V1::BalanceSheetControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family

    @user.api_keys.active.destroy_all

    @auth = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@auth.id}")
  end

  test "should require authentication" do
    get "/api/v1/balance_sheet"
    assert_response :unauthorized
  end

  test "should return balance sheet with net worth data" do
    get "/api/v1/balance_sheet", headers: api_headers(@auth)

    assert_response :success
    response_body = JSON.parse(response.body)

    assert response_body.key?("currency")
    assert response_body.key?("net_worth")
    assert response_body.key?("assets")
    assert response_body.key?("liabilities")
    assert response_body.key?("asset_groups")
    assert response_body.key?("liability_groups")

    %w[net_worth assets liabilities].each do |field|
      assert response_body[field].key?("amount"), "#{field} should have amount"
      assert response_body[field].key?("currency"), "#{field} should have currency"
      assert response_body[field].key?("formatted"), "#{field} should have formatted"
    end
  end

  test "should return native and converted balances for account distribution" do
    @family.update!(currency: "NGN")
    account = @family.accounts.create!(
      owner: @user,
      name: "Rise",
      balance: 10,
      currency: "USD",
      accountable: Investment.new
    )
    ExchangeRate.create!(
      from_currency: "USD",
      to_currency: "NGN",
      date: Date.current,
      rate: 1500
    )

    get "/api/v1/balance_sheet", headers: api_headers(@auth)

    assert_response :success
    response_body = JSON.parse(response.body)
    investment_group = response_body.fetch("asset_groups").find { |group| group["account_type"] == "investment" }
    account_payload = investment_group.fetch("accounts").find { |payload| payload["id"] == account.id }

    assert_equal "USD", account_payload["currency"]
    assert_equal "USD", account_payload.dig("balance", "currency")
    assert_equal "NGN", account_payload.dig("converted_balance", "currency")
    assert_equal BigDecimal("15000"), BigDecimal(account_payload.dig("converted_balance", "amount").to_s)
  end

  private

    def api_headers(auth)
      { "X-Api-Key" => auth.display_key }
    end
end
