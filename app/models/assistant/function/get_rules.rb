# frozen_string_literal: true

class Assistant::Function::GetRules < Assistant::Function
  class << self
    def name
      "get_rules"
    end

    def description
      <<~INSTRUCTIONS
        Lists the user's transaction automation rules.

        Each rule has conditions (which transactions it matches) and actions (what it does to them).
        Use this before creating a rule to avoid duplicates, or when the user asks what automations
        they have set up.
      INSTRUCTIONS
    end
  end

  def call(params = {})
    rules = family.rules.order(created_at: :desc)

    {
      total_rules: rules.count,
      rules: rules.map { |rule| serialize_rule(rule) }
    }
  end

  private
    def serialize_rule(rule)
      {
        id: rule.id,
        name: rule.name,
        active: rule.active,
        resource_type: rule.resource_type,
        effective_date: rule.effective_date,
        conditions: rule.conditions.map { |condition| serialize_condition(condition) },
        actions: rule.actions.map { |action| serialize_action(action) }
      }
    end

    def serialize_condition(condition)
      if condition.compound?
        {
          condition_type: "compound",
          operator: condition.operator,
          sub_conditions: condition.sub_conditions.map { |sub| serialize_condition(sub) }
        }
      else
        {
          condition_type: condition.condition_type,
          operator: condition.operator,
          value: condition.value,
          display_value: display_value_for(condition.condition_type, condition.value)
        }
      end
    end

    def serialize_action(action)
      {
        action_type: action.action_type,
        value: action.value,
        display_value: display_value_for(action.action_type, action.value)
      }
    end

    # Select-type conditions/actions store record ids; resolve them to names so
    # the model can talk about rules without extra lookups.
    def display_value_for(type, value)
      return nil if value.blank?

      case type
      when "transaction_category", "set_transaction_category"
        family.categories.find_by(id: value)&.name
      when "transaction_merchant", "set_transaction_merchant"
        family.merchants.find_by(id: value)&.name
      when "transaction_account", "set_as_transfer_or_payment"
        family.accounts.find_by(id: value)&.name
      when "set_transaction_tags"
        family.tags.find_by(id: value)&.name
      else
        value
      end
    end
end
