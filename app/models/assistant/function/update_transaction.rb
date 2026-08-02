# frozen_string_literal: true

class Assistant::Function::UpdateTransaction < Assistant::Function
  CLEAR_SENTINELS = [ "none", "uncategorized", "" ].freeze

  class << self
    def name
      "update_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Updates a single existing transaction. Use get_transactions first to find the
        transaction id.

        Only the provided fields are changed. Category, merchant and tags accept a name or id;
        pass "none" to clear the category or merchant. Tags replace the full tag list; pass an
        empty array to remove all tags. Amounts are positive with nature indicating direction.

        For recurring fixes across many transactions, prefer create_rule instead. Split
        transactions cannot be edited here.

        Always tell the user exactly what will change and get their confirmation before calling this.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "transaction_id" ],
      properties: {
        transaction_id: { type: "string", description: "Transaction id from get_transactions" },
        name: { type: "string", description: "New transaction name" },
        date: { type: "string", description: "New date (YYYY-MM-DD)" },
        amount: { type: "number", description: "New positive amount", exclusiveMinimum: 0 },
        nature: { type: "string", enum: [ "expense", "income" ], description: "Required when amount is provided" },
        category: { type: "string", description: "Category name or id, or 'none' to clear" },
        merchant: { type: "string", description: "Merchant name or id, or 'none' to clear" },
        tags: { type: "array", items: { type: "string" }, description: "Full replacement tag list (names or ids); [] clears all tags" },
        notes: { type: "string", description: "New notes" },
        excluded: { type: "boolean", description: "Exclude from budgets and reports" }
      }
    )
  end

  def call(params = {})
    transaction = find_transaction(params["transaction_id"])
    return error("transaction_not_found", "No editable transaction found with id '#{params["transaction_id"]}'. Use get_transactions to find ids.") unless transaction

    entry = transaction.entry
    return error("split_transaction", "Split transactions cannot be edited here; ask the user to use the split editor.") if entry.split_child? || entry.split_parent?

    entry_changes, entryable_changes, err = build_changes(params, entry)
    return err if err

    if entry_changes.empty? && entryable_changes.empty? && params["tags"].nil? && params["excluded"].nil?
      return error("nothing_to_update", "No fields provided to update.")
    end

    Entry.transaction do
      unless entry.update(entry_changes.merge(entryable_attributes: entryable_changes.merge(id: entry.entryable_id)))
        raise ActiveRecord::Rollback
      end

      unless params["tags"].nil?
        tags = []
        Array(params["tags"]).each do |tag_value|
          tag = resolve_family_record(:tag, tag_value)
          return error("tag_not_found", "No tag found matching '#{tag_value}'. Use get_tags to list them.") unless tag
          tags << tag
        end
        transaction.tag_ids = tags.map(&:id)
        transaction.save!
        transaction.lock_attr!(:tag_ids) if tags.any?
      end

      entry.mark_user_modified!
      entry.lock_saved_attributes!
      entry.sync_account_later
    end

    if entry.errors.any?
      error("validation_failed", entry.errors.full_messages.join("; "))
    else
      { success: true, transaction: serialize(entry.reload), message: "Transaction '#{entry.name}' updated." }
    end
  end

  private
    def find_transaction(transaction_id)
      return nil unless valid_uuid?(transaction_id)

      family.transactions
            .joins(entry: :account)
            .merge(Account.writable_by(user))
            .where(accounts: { status: %w[draft active] })
            .find_by(id: transaction_id)
    end

    def build_changes(params, entry)
      entry_changes = {}
      entryable_changes = {}

      entry_changes[:name] = params["name"].to_s.strip if params["name"].present?
      entry_changes[:notes] = params["notes"] unless params["notes"].nil?

      if params["date"].present?
        date = parse_date(params["date"])
        return [ nil, nil, error("invalid_date", "date must be a valid YYYY-MM-DD date.") ] unless date
        entry_changes[:date] = date
      end

      if params["amount"].present?
        amount = params["amount"].to_f
        return [ nil, nil, error("invalid_amount", "Amount must be a positive number.") ] unless amount.positive?
        return [ nil, nil, error("nature_required", "Provide nature ('expense' or 'income') when changing the amount.") ] if params["nature"].blank?
        entry_changes[:amount] = params["nature"] == "income" ? -amount.abs : amount.abs
      end

      entry_changes[:excluded] = params["excluded"] unless params["excluded"].nil?

      unless params["category"].nil?
        if clear_value?(params["category"])
          entryable_changes[:category_id] = nil
        else
          category = resolve_family_record(:category, params["category"])
          return [ nil, nil, error("category_not_found", "No category found matching '#{params["category"]}'. Use get_categories to list them.") ] unless category
          entryable_changes[:category_id] = category.id
        end
      end

      unless params["merchant"].nil?
        if clear_value?(params["merchant"])
          entryable_changes[:merchant_id] = nil
        else
          merchant = resolve_family_record(:merchant, params["merchant"])
          return [ nil, nil, error("merchant_not_found", "No merchant found matching '#{params["merchant"]}'.") ] unless merchant
          entryable_changes[:merchant_id] = merchant.id
        end
      end

      [ entry_changes, entryable_changes, nil ]
    end

    def clear_value?(value)
      CLEAR_SENTINELS.include?(value.to_s.downcase.strip)
    end

    def serialize(entry)
      txn = entry.transaction
      {
        id: txn.id,
        entry_id: entry.id,
        name: entry.name,
        date: entry.date,
        amount: entry.amount_money.format,
        nature: entry.amount.negative? ? "income" : "expense",
        currency: entry.currency,
        account: entry.account.name,
        category: txn.category&.name,
        merchant: txn.merchant&.name,
        tags: txn.tags.map(&:name),
        notes: entry.notes,
        excluded: entry.excluded
      }
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
