# frozen_string_literal: true

require "test_helper"

class Api::V1::BudgetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )
    @read_write_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @budget = @family.budgets.create!(
      start_date: 3.months.ago.beginning_of_month.to_date,
      end_date: 3.months.ago.end_of_month.to_date,
      budgeted_spending: 3000,
      expected_income: 5000,
      currency: "USD"
    )

    category = categories(:food_and_drink)
    @budget_category = @budget.budget_categories.create!(
      category: category,
      budgeted_spending: 500,
      currency: "USD"
    )

    other_family = families(:empty)
    @other_budget = other_family.budgets.create!(
      start_date: 4.months.ago.beginning_of_month.to_date,
      end_date: 4.months.ago.end_of_month.to_date,
      budgeted_spending: 1000,
      expected_income: 2000,
      currency: "USD"
    )
  end

  test "lists budgets scoped to the current family" do
    get api_v1_budgets_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data.key?("budgets")
    assert response_data.key?("pagination")
    assert_includes response_data["budgets"].map { |budget| budget["id"] }, @budget.id
    assert_not_includes response_data["budgets"].map { |budget| budget["id"] }, @other_budget.id

    budget_response = response_data["budgets"].find { |budget| budget["id"] == @budget.id }
    %w[
      actual_spending
      actual_spending_cents
      actual_income
      actual_income_cents
      available_to_spend
      available_to_spend_cents
      available_to_allocate
      available_to_allocate_cents
    ].each do |derived_field|
      assert_not budget_response.key?(derived_field), "Expected budget index to omit #{derived_field}"
    end
  end

  test "shows a budget" do
    get api_v1_budget_url(@budget.id), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal @budget.id, response_data["id"]
    assert_equal @budget.start_date.to_s, response_data["start_date"]
    assert_equal "USD", response_data["currency"]
    assert_equal true, response_data["initialized"]
    assert_kind_of Integer, response_data["budgeted_spending_cents"]
    assert_kind_of Integer, response_data["actual_spending_cents"]
    assert_kind_of Integer, response_data["actual_income_cents"]
    assert_kind_of Integer, response_data["available_to_spend_cents"]
    assert_kind_of Integer, response_data["available_to_allocate_cents"]
  end

  test "returns not found for another family's budget" do
    get api_v1_budget_url(@other_budget.id), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "returns not found for malformed budget id" do
    get api_v1_budget_url("not-a-uuid"), headers: api_headers(@api_key)

    assert_response :not_found
    response_data = JSON.parse(response.body)
    assert_equal "record_not_found", response_data["error"]
  end

  test "filters budgets by date range" do
    get api_v1_budgets_url,
        params: { start_date: @budget.start_date.to_s, end_date: @budget.end_date.to_s },
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["budgets"].map { |budget| budget["id"] }, @budget.id
  end

  test "updates a budget" do
    patch api_v1_budget_url(@budget),
          params: { budget: { budgeted_spending: 3500, expected_income: 5500 } },
          headers: api_headers(@read_write_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal 350000, response_data["budgeted_spending_cents"]
    assert_equal 550000, response_data["expected_income_cents"]
  end

  test "copies previous initialized budget" do
    source_budget = @family.budgets.create!(
      start_date: Date.new(2035, 1, 1),
      end_date: Date.new(2035, 1, 31),
      budgeted_spending: 4200,
      expected_income: 6200,
      currency: "USD"
    )
    target_budget = @family.budgets.create!(
      start_date: Date.new(2035, 2, 1),
      end_date: Date.new(2035, 2, 28),
      currency: "USD"
    )

    post copy_previous_api_v1_budget_url(target_budget), headers: api_headers(@read_write_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal (source_budget.budgeted_spending * 100).to_i, response_data["budgeted_spending_cents"]
    assert_equal (source_budget.expected_income * 100).to_i, response_data["expected_income_cents"]
  end

  test "rejects budget update with read-only key" do
    patch api_v1_budget_url(@budget),
          params: { budget: { budgeted_spending: 3500 } },
          headers: api_headers(@api_key)

    assert_response :forbidden
  end

  test "rejects invalid date filters" do
    get api_v1_budgets_url, params: { start_date: "03/01/2024" }, headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "requires authentication" do
    get api_v1_budgets_url

    assert_response :unauthorized
  end

  test "requires read scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "mobile",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    api_key_without_read.save!(validate: false)

    get api_v1_budgets_url, headers: api_headers(api_key_without_read)

    assert_response :forbidden
  ensure
    api_key_without_read&.destroy
  end
end
