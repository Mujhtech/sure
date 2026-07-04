# frozen_string_literal: true

require "test_helper"

class Api::V1::ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    @account = Account.create!(
      family: @family,
      name: "API Report Checking",
      balance: 1000,
      currency: "USD",
      accountable: Depository.new
    )

    @category = @family.categories.create!(
      name: "API Groceries",
      color: "#4CAF50",
      lucide_icon: "shopping-cart"
    )

    @account.entries.create!(
      name: "API Grocery Run",
      date: Date.current,
      amount: 42.25,
      currency: "USD",
      entryable: Transaction.new(category: @category)
    )

    @account.entries.create!(
      name: "API Paycheck",
      date: Date.current,
      amount: -1500,
      currency: "USD",
      entryable: Transaction.new
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
  end

  test "should require authentication" do
    get "/api/v1/reports"

    assert_response :unauthorized
  end

  test "should return report dashboard payload" do
    get "/api/v1/reports",
        params: {
          period_type: "custom",
          start_date: Date.current.beginning_of_month.to_s,
          end_date: Date.current.end_of_month.to_s
        },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal @family.currency, response_data["currency"]
    assert_equal "custom", response_data.dig("period", "type")
    assert response_data.key?("summary")
    assert response_data.key?("trends")
    assert response_data.key?("net_worth")
    assert response_data.key?("transactions_breakdown")
    assert response_data.key?("investments")

    grocery_row = response_data["transactions_breakdown"].find { |row| row["category_name"] == "API Groceries" }
    assert_not_nil grocery_row
    assert_equal "expense", grocery_row["type"]
    assert_equal 1, grocery_row["count"]
    assert_equal "USD", grocery_row.dig("total", "currency")
  end

  test "should allow read write keys" do
    read_write_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}",
      source: "web"
    )
    Redis.new.del("api_rate_limit:#{read_write_key.id}")

    get "/api/v1/reports", headers: api_headers(read_write_key)

    assert_response :success
  end

  test "should reject invalid period type" do
    get "/api/v1/reports",
        params: { period_type: "weeklyish" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_match "period_type", response_data["message"]
  end

  test "should reject non iso dates" do
    get "/api/v1/reports",
        params: { start_date: "06/01/2026" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_equal "start_date must be an ISO 8601 date", response_data["message"]
  end

  test "should reject malformed uuid filters" do
    get "/api/v1/reports",
        params: { filter_account_id: "not-a-uuid" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_equal "filter_account_id must be a valid UUID", response_data["message"]
  end

  test "should export transaction breakdown csv" do
    get "/api/v1/reports/export_transactions",
        params: {
          period_type: "custom",
          start_date: Date.current.beginning_of_month.to_s,
          end_date: Date.current.end_of_month.to_s
        },
        headers: api_headers(@api_key)

    assert_response :success
    assert_match "text/csv", response.media_type
    assert_match "attachment", response.headers["Content-Disposition"]
    assert_includes response.body, "Category"
    assert_includes response.body, "INCOME"
    assert_includes response.body, "EXPENSES"
    assert_includes response.body, "API Groceries"
  end

  test "should reject non iso dates on transaction export" do
    get "/api/v1/reports/export_transactions",
        params: { start_date: "06/01/2026" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_equal "start_date must be an ISO 8601 date", response_data["message"]
  end

  private

    def api_headers(auth)
      { "X-Api-Key" => auth.display_key }
    end
end
