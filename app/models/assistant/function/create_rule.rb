# frozen_string_literal: true

class Assistant::Function::CreateRule < Assistant::Function
  CONDITION_TYPES = {
    "transaction_name" => { kind: :text },
    "transaction_details" => { kind: :text },
    "transaction_notes" => { kind: :text },
    "transaction_amount" => { kind: :number },
    "transaction_type" => { kind: :fixed_select, values: %w[income expense transfer], operators: [ "=" ] },
    "transaction_merchant" => { kind: :record_select, lookup: :merchant },
    "transaction_category" => { kind: :record_select, lookup: :category },
    "transaction_account" => { kind: :record_select, lookup: :account }
  }.freeze

  ACTION_TYPES = {
    "set_transaction_category" => { value: :category },
    "set_transaction_tags" => { value: :tag },
    "set_transaction_merchant" => { value: :merchant },
    "set_transaction_name" => { value: :text },
    "set_investment_activity_label" => { value: :activity_label },
    "set_as_transfer_or_payment" => { value: :account },
    "exclude_transaction" => { value: :none },
    "auto_categorize" => { value: :none },
    "auto_detect_merchants" => { value: :none }
  }.freeze

  OPERATORS_BY_KIND = {
    text: [ "like", "=", "is_null" ],
    number: [ ">", ">=", "<", "<=", "=" ],
    record_select: [ "=", "is_null" ]
  }.freeze

  class << self
    def name
      "create_rule"
    end

    def description
      <<~INSTRUCTIONS
        Creates a transaction automation rule for the user. Rules match transactions via
        conditions (ALL conditions must match) and apply actions to them automatically as new
        transactions sync in.

        Typical use: the user wants transactions matching a pattern (e.g. name contains "Uber")
        to always get a specific category, merchant, tag, or name.

        Condition types and their operators:
        - transaction_name, transaction_details, transaction_notes (text): "like" (contains, case-insensitive), "=", "is_null"
        - transaction_amount (number, absolute value): ">", ">=", "<", "<=", "="
        - transaction_type: "=" with value "income", "expense" or "transfer"
        - transaction_merchant, transaction_category, transaction_account: "=" with the record's
          name or id (use get_categories/get_accounts/get_transactions for exact names), or "is_null"

        Action types:
        - set_transaction_category (value: category name or id)
        - set_transaction_tags (value: tag name or id; tag is added, existing tags kept)
        - set_transaction_merchant (value: merchant name or id)
        - set_transaction_name (value: new display name)
        - set_investment_activity_label (value: activity label)
        - set_as_transfer_or_payment (value: the counterpart account name or id)
        - exclude_transaction, auto_categorize, auto_detect_merchants (no value)

        By default the rule only affects transactions going forward. Set apply_to_existing to true
        to also run it against current matching transactions (manually locked attributes are never
        overwritten). Before creating, confirm the user actually wants a rule, and report the
        affected transaction count from the response back to them.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "name", "conditions", "actions" ],
      properties: {
        name: {
          type: "string",
          description: "Short human-readable rule name, e.g. 'Categorize Uber rides'"
        },
        conditions: {
          type: "array",
          minItems: 1,
          description: "Conditions a transaction must ALL match",
          items: {
            type: "object",
            properties: {
              condition_type: { type: "string", enum: CONDITION_TYPES.keys },
              operator: { type: "string", enum: OPERATORS_BY_KIND.values.flatten.uniq },
              value: { type: "string", description: "Comparison value. Omit for is_null." }
            },
            required: [ "condition_type", "operator" ],
            additionalProperties: false
          }
        },
        actions: {
          type: "array",
          minItems: 1,
          description: "Actions applied to matching transactions",
          items: {
            type: "object",
            properties: {
              action_type: { type: "string", enum: ACTION_TYPES.keys },
              value: { type: "string", description: "Action value (see action types). Omit for valueless actions." }
            },
            required: [ "action_type" ],
            additionalProperties: false
          }
        },
        effective_date: {
          type: "string",
          description: "YYYY-MM-DD. Rule only considers transactions on/after this date. Omit for all dates."
        },
        apply_to_existing: {
          type: "boolean",
          description: "Also apply the rule to currently matching transactions now (default false)."
        }
      }
    )
  end

  def call(params = {})
    name = params["name"].to_s.strip
    return error("name_required", "Please provide a rule name.") if name.blank?

    conditions = Array(params["conditions"])
    actions = Array(params["actions"])
    return error("conditions_required", "At least one condition is required.") if conditions.empty?
    return error("actions_required", "At least one action is required.") if actions.empty?

    rule = family.rules.build(name: name, resource_type: "transaction", active: true)

    if params["effective_date"].present?
      date = parse_date(params["effective_date"])
      return error("invalid_effective_date", "effective_date must be a valid YYYY-MM-DD date.") unless date
      rule.effective_date = date
    end

    conditions.each do |condition|
      attrs, err = condition_attributes(condition)
      return err if err
      rule.conditions.build(attrs)
    end

    actions.each do |action|
      attrs, err = action_attributes(action)
      return err if err
      rule.actions.build(attrs)
    end

    unless rule.save
      return error("validation_failed", rule.errors.full_messages.join("; "))
    end

    affected_count = rule.affected_resource_count
    applied = false

    if params["apply_to_existing"]
      rule.apply_later
      applied = true
    end

    {
      success: true,
      rule: {
        id: rule.id,
        name: rule.name,
        active: rule.active,
        effective_date: rule.effective_date,
        conditions: rule.conditions.map { |c| { condition_type: c.condition_type, operator: c.operator, value: c.value } },
        actions: rule.actions.map { |a| { action_type: a.action_type, value: a.value } }
      },
      currently_matching_transactions: affected_count,
      applied_to_existing: applied,
      message: applied ?
        "Rule '#{rule.name}' created and being applied to #{affected_count} matching transaction(s). It will also run automatically on new transactions." :
        "Rule '#{rule.name}' created. It matches #{affected_count} existing transaction(s) but was NOT applied retroactively; it will run on new transactions going forward."
    }
  end

  private
    def condition_attributes(condition)
      condition_type = condition["condition_type"].to_s
      operator = condition["operator"].to_s
      value = condition["value"]

      spec = CONDITION_TYPES[condition_type]
      return [ nil, error("invalid_condition_type", "Unknown condition_type '#{condition_type}'. Valid: #{CONDITION_TYPES.keys.join(", ")}") ] unless spec

      allowed_operators = spec[:operators] || OPERATORS_BY_KIND.fetch(spec[:kind], OPERATORS_BY_KIND[:record_select])
      unless allowed_operators.include?(operator)
        return [ nil, error("invalid_operator", "Operator '#{operator}' is not valid for #{condition_type}. Valid: #{allowed_operators.join(", ")}") ]
      end

      if operator == "is_null"
        return [ { condition_type: condition_type, operator: operator, value: nil }, nil ]
      end

      return [ nil, error("value_required", "Condition #{condition_type} requires a value for operator '#{operator}'.") ] if value.blank?

      case spec[:kind]
      when :number
        return [ nil, error("invalid_value", "Condition #{condition_type} requires a numeric value.") ] unless numeric?(value)
      when :fixed_select
        unless spec[:values].include?(value)
          return [ nil, error("invalid_value", "Condition #{condition_type} value must be one of: #{spec[:values].join(", ")}") ]
        end
      when :record_select
        record, err = resolve_record(spec[:lookup], value)
        return [ nil, err ] if err
        value = record.id
      end

      [ { condition_type: condition_type, operator: operator, value: value.to_s }, nil ]
    end

    def action_attributes(action)
      action_type = action["action_type"].to_s
      value = action["value"]

      spec = ACTION_TYPES[action_type]
      return [ nil, error("invalid_action_type", "Unknown action_type '#{action_type}'. Valid: #{ACTION_TYPES.keys.join(", ")}") ] unless spec

      case spec[:value]
      when :none
        value = nil
      when :text
        return [ nil, error("value_required", "Action #{action_type} requires a value.") ] if value.blank?
      when :activity_label
        unless Transaction::ACTIVITY_LABELS.include?(value)
          return [ nil, error("invalid_value", "Action #{action_type} value must be one of: #{Transaction::ACTIVITY_LABELS.join(", ")}") ]
        end
      else
        return [ nil, error("value_required", "Action #{action_type} requires a value.") ] if value.blank?
        record, err = resolve_record(spec[:value], value)
        return [ nil, err ] if err
        value = record.id
      end

      [ { action_type: action_type, value: value&.to_s }, nil ]
    end

    def resolve_record(lookup, value)
      record = resolve_family_record(lookup, value)
      return [ record, nil ] if record

      known = resolve_family_scope(lookup).limit(50).pluck(:name).join(", ")
      [ nil, error("#{lookup}_not_found", "No #{lookup} found matching '#{value}'. Known #{lookup.to_s.pluralize}: #{known}") ]
    end

    def resolve_family_scope(lookup)
      case lookup
      when :category then family.categories
      when :merchant then family.merchants
      when :account  then family.accounts
      when :tag      then family.tags
      end
    end

    def numeric?(value)
      Float(value)
      true
    rescue ArgumentError, TypeError
      false
    end

    def parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end

    def error(key, message)
      { success: false, error: key, message: message }
    end
end
