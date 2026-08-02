require "test_helper"

class Assistant::Function::CreateRuleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::CreateRule.new(@user)
    @category = @family.categories.first
  end

  test "to_definition returns correct schema" do
    definition = @fn.to_definition
    assert_equal "create_rule", definition[:name]
    assert_not_empty definition[:description]
    assert_equal %w[name conditions actions], definition[:params_schema][:required]
  end

  test "creates a categorization rule from a name pattern" do
    result = nil

    assert_difference "@family.rules.count" do
      result = @fn.call(
        "name" => "Categorize Uber rides",
        "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "Uber" } ],
        "actions" => [ { "action_type" => "set_transaction_category", "value" => @category.name } ]
      )
    end

    assert result[:success], result[:message]
    rule = @family.rules.find(result[:rule][:id])
    assert rule.active
    assert_equal "transaction", rule.resource_type
    assert_equal [ [ "transaction_name", "like", "Uber" ] ], rule.conditions.map { |c| [ c.condition_type, c.operator, c.value ] }
    assert_equal [ [ "set_transaction_category", @category.id ] ], rule.actions.map { |a| [ a.action_type, a.value ] }
    assert_not result[:applied_to_existing]
    assert result.key?(:currently_matching_transactions)
  end

  test "resolves select values case-insensitively by name" do
    result = @fn.call(
      "name" => "Test rule",
      "conditions" => [ { "condition_type" => "transaction_category", "operator" => "=", "value" => @category.name.upcase } ],
      "actions" => [ { "action_type" => "exclude_transaction" } ]
    )

    assert result[:success], result[:message]
    assert_equal @category.id, result[:rule][:conditions].first[:value]
  end

  test "accepts record ids directly" do
    result = @fn.call(
      "name" => "Test rule by id",
      "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "Coffee" } ],
      "actions" => [ { "action_type" => "set_transaction_category", "value" => @category.id } ]
    )

    assert result[:success], result[:message]
    assert_equal @category.id, result[:rule][:actions].first[:value]
  end

  test "apply_to_existing enqueues RuleJob" do
    assert_enqueued_with(job: RuleJob) do
      result = @fn.call(
        "name" => "Apply now",
        "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "Uber" } ],
        "actions" => [ { "action_type" => "set_transaction_category", "value" => @category.name } ],
        "apply_to_existing" => true
      )

      assert result[:success], result[:message]
      assert result[:applied_to_existing]
    end
  end

  test "rejects unknown category with helpful message" do
    assert_no_difference "@family.rules.count" do
      result = @fn.call(
        "name" => "Bad rule",
        "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "Uber" } ],
        "actions" => [ { "action_type" => "set_transaction_category", "value" => "Nonexistent Category" } ]
      )

      assert_not result[:success]
      assert_equal "category_not_found", result[:error]
    end
  end

  test "rejects invalid operator for condition type" do
    result = @fn.call(
      "name" => "Bad operator",
      "conditions" => [ { "condition_type" => "transaction_amount", "operator" => "like", "value" => "50" } ],
      "actions" => [ { "action_type" => "exclude_transaction" } ]
    )

    assert_not result[:success]
    assert_equal "invalid_operator", result[:error]
  end

  test "rejects non-numeric amount value" do
    result = @fn.call(
      "name" => "Bad amount",
      "conditions" => [ { "condition_type" => "transaction_amount", "operator" => ">", "value" => "lots" } ],
      "actions" => [ { "action_type" => "exclude_transaction" } ]
    )

    assert_not result[:success]
    assert_equal "invalid_value", result[:error]
  end

  test "rejects missing conditions or actions" do
    result = @fn.call("name" => "Empty", "conditions" => [], "actions" => [ { "action_type" => "exclude_transaction" } ])
    assert_equal "conditions_required", result[:error]

    result = @fn.call("name" => "Empty", "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "x" } ], "actions" => [])
    assert_equal "actions_required", result[:error]
  end

  test "supports is_null operator without a value" do
    result = @fn.call(
      "name" => "Uncategorized coffee",
      "conditions" => [
        { "condition_type" => "transaction_category", "operator" => "is_null" },
        { "condition_type" => "transaction_name", "operator" => "like", "value" => "Coffee" }
      ],
      "actions" => [ { "action_type" => "set_transaction_category", "value" => @category.name } ]
    )

    assert result[:success], result[:message]
    null_condition = result[:rule][:conditions].find { |c| c[:operator] == "is_null" }
    assert_nil null_condition[:value]
  end

  test "rejects invalid effective_date" do
    result = @fn.call(
      "name" => "Bad date",
      "conditions" => [ { "condition_type" => "transaction_name", "operator" => "like", "value" => "Uber" } ],
      "actions" => [ { "action_type" => "exclude_transaction" } ],
      "effective_date" => "not-a-date"
    )

    assert_not result[:success]
    assert_equal "invalid_effective_date", result[:error]
  end
end
