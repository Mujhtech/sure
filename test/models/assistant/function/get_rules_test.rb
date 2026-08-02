require "test_helper"

class Assistant::Function::GetRulesTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @fn = Assistant::Function::GetRules.new(@user)
  end

  test "lists rules with resolved display values" do
    category = @family.categories.first
    rule = @family.rules.create!(name: "Coffee rule", resource_type: "transaction", active: true) do |r|
      r.conditions.build(condition_type: "transaction_name", operator: "like", value: "Coffee")
      r.actions.build(action_type: "set_transaction_category", value: category.id)
    end

    result = @fn.call

    serialized = result[:rules].find { |r| r[:id] == rule.id }
    assert serialized, "expected created rule in output"
    assert_equal "Coffee rule", serialized[:name]
    assert serialized[:active]

    condition = serialized[:conditions].first
    assert_equal [ "transaction_name", "like", "Coffee" ], [ condition[:condition_type], condition[:operator], condition[:value] ]

    action = serialized[:actions].first
    assert_equal "set_transaction_category", action[:action_type]
    assert_equal category.id, action[:value]
    assert_equal category.name, action[:display_value]
  end

  test "returns total count" do
    result = @fn.call
    assert_equal @family.rules.count, result[:total_rules]
  end
end
