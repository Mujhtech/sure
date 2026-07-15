# frozen_string_literal: true

require "test_helper"

class Api::V1::MonthlyDumpsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all
    @month_start = Date.current.prev_month.beginning_of_month.to_date

    @api_key = ApiKey.create!(
      user: @user,
      name: "Monthly Dump Read Key",
      scopes: [ "read" ],
      display_key: "monthly_dump_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    @account = Account.create!(
      family: @family,
      name: "Monthly Dump Checking",
      balance: 2500,
      currency: @family.currency,
      accountable: Depository.new
    )
    @category = @family.categories.create!(
      name: "Monthly Dump Dining",
      color: "#FF735C",
      lucide_icon: "utensils"
    )

    @account.entries.create!(
      name: "Monthly Dinner",
      date: @month_start + 10.days,
      amount: 125,
      currency: @family.currency,
      entryable: Transaction.new(category: @category)
    )
    @account.entries.create!(
      name: "Monthly Paycheck",
      date: @month_start + 2.days,
      amount: -1800,
      currency: @family.currency,
      entryable: Transaction.new
    )

    MonthlyDump::PersonaRefiner.any_instance.stubs(:call).returns({
      key: "achiever",
      title: "The Achiever",
      headline: "You turned targets into receipts.",
      description: "Progress became visible this month.",
      closing_line: "Goal energy, backed by numbers.",
      symbol: "trophy.fill",
      source: "ai"
    })

    Redis.new.del("api_rate_limit:#{@api_key.id}")
  end

  test "requires authentication" do
    get "/api/v1/monthly_dump"

    assert_response :unauthorized
  end

  test "returns the latest completed month by default" do
    get "/api/v1/monthly_dump", headers: api_headers

    assert_response :success
    data = JSON.parse(response.body)

    assert_equal @month_start.strftime("%Y-%m"), data.dig("period", "month")
    assert_equal @month_start.end_of_month.iso8601, data.dig("period", "end_date")
    assert_equal true, data.dig("period", "complete")
    assert_operator Date.iso8601(data.dig("period", "end_date")), :<, Date.current
    assert_equal @family.currency, data["currency"]
    assert_equal @family.currency, data.dig("summary", "income", "currency")
    assert_kind_of Numeric, data.dig("summary", "savings_rate")
    assert_kind_of Numeric, data.dig("summary", "income_change_percent")
    assert_kind_of Numeric, data.dig("summary", "expense_change_percent")
    assert_operator data.dig("activity", "transaction_count"), :>=, 2
    assert_equal @month_start.end_of_month.day, data.dig("activity", "tracked_days")
    assert_equal "Monthly Dump Dining", data.dig("categories", 0, "category_name")
    assert_equal "achiever", data.dig("persona", "key")
    assert_equal "ai", data.dig("persona", "source")
  end

  test "allows an older completed month" do
    requested_month = @month_start.prev_month

    get "/api/v1/monthly_dump",
        params: { month: requested_month.strftime("%Y-%m") },
        headers: api_headers

    assert_response :success
    assert_equal requested_month.strftime("%Y-%m"), JSON.parse(response.body).dig("period", "month")
  end

  test "rejects the current month" do
    get "/api/v1/monthly_dump",
        params: { month: Date.current.strftime("%Y-%m") },
        headers: api_headers

    assert_response :unprocessable_entity
    data = JSON.parse(response.body)
    assert_equal "month_not_complete", data["error"]
    assert_equal @month_start.strftime("%Y-%m"), data["latest_available_month"]
  end

  test "rejects malformed month values" do
    get "/api/v1/monthly_dump",
        params: { month: "06/2026" },
        headers: api_headers

    assert_response :unprocessable_entity
    data = JSON.parse(response.body)
    assert_equal "validation_failed", data["error"]
    assert_equal "month must use YYYY-MM format", data["message"]
  end

  private
    def api_headers
      { "X-Api-Key" => @api_key.display_key }
    end
end
