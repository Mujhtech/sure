require "test_helper"

class Assistant::Function::CreateBudgetTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::CreateBudget.new(@user)
  end

  test "to_definition returns correct schema" do
    definition = @fn.to_definition
    assert_equal "create_budget", definition[:name]
    assert_not_empty definition[:description]
    assert definition[:params_schema][:properties].key?(:month)
  end

  test "bootstraps a budget for a past month with targets" do
    month = 2.months.ago.to_date

    result = nil
    assert_difference "@family.budgets.count" do
      result = @fn.call("month" => month.iso8601, "budgeted_spending" => 4200, "expected_income" => 6000)
    end

    assert result[:success], result[:message]
    budget = @family.budgets.find(result[:budget][:id])
    assert_equal month.beginning_of_month, budget.start_date
    assert_equal 4200, budget.budgeted_spending
    assert_equal 6000, budget.expected_income
    assert_equal budget.id, result[:budget][:budget_id]
    assert result[:budget][:name].present?
    assert result[:budget][:budgeted_spending_formatted].present?
  end

  test "updates targets on the existing current-month budget" do
    existing = budgets(:one)

    result = nil
    assert_no_difference "@family.budgets.count" do
      result = @fn.call("budgeted_spending" => 5500)
    end

    assert result[:success], result[:message]
    assert_equal existing.id, result[:budget][:id]
    assert_equal 5500, existing.reload.budgeted_spending
    assert_equal 7000, existing.expected_income
    assert_includes result[:message], "updated"
  end

  test "rejects invalid month and out-of-range month" do
    result = @fn.call("month" => "not-a-date")
    assert_equal "invalid_month", result[:error]

    result = @fn.call("month" => "1990-01-01")
    assert_equal "invalid_month", result[:error]
  end

  test "rejects non-positive amounts" do
    result = @fn.call("budgeted_spending" => 0)
    assert_equal "invalid_budgeted_spending", result[:error]

    result = @fn.call("expected_income" => -5)
    assert_equal "invalid_expected_income", result[:error]
  end
end
