# frozen_string_literal: true

class Assistant::Function::CreateTransaction < Assistant::Function
  class << self
    def name
      "create_transaction"
    end

    def description
      <<~INSTRUCTIONS
        Creates a manual transaction in one of the user's accounts.

        Use when the user asks to record a purchase, income, or other cash movement that isn't
        synced automatically (e.g. "add a $40 dinner expense to my checking account yesterday").

        Amounts are always positive; the nature field determines direction ("expense" = money out,
        "income" = money in). Account and category accept a name or id (use get_accounts /
        get_categories for exact names).

        Always confirm the account, amount, nature and date with the user before calling this.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "account", "name", "amount", "nature" ],
      properties: {
        account: { type: "string", description: "Account name or id the transaction belongs to" },
        name: { type: "string", description: "Transaction name/description, e.g. 'Dinner at Nobu'" },
        amount: { type: "number", description: "Positive amount in the account's currency", exclusiveMinimum: 0 },
        nature: { type: "string", enum: [ "expense", "income" ], description: "expense = money out, income = money in" },
        date: { type: "string", description: "YYYY-MM-DD (defaults to today)" },
        currency: { type: "string", description: "ISO currency code (defaults to the account's currency)" },
        category: { type: "string", description: "Category name or id (optional)" },
        merchant: { type: "string", description: "Existing merchant name or id (optional)" },
        tags: { type: "array", items: { type: "string" }, description: "Existing tag names or ids (optional)" },
        notes: { type: "string", description: "Free-form notes (optional)" }
      }
    )
  end

  def call(params = {})
    account = writable_accounts.find { |a| a.id == params["account"] } ||
              writable_accounts.find { |a| a.name.casecmp?(params["account"].to_s.strip) }
    unless account
      return error("account_not_found", "No writable account found matching '#{params["account"]}'. Available accounts: #{writable_accounts.map(&:name).join(", ")}")
    end

    amount = params["amount"].to_f
    return error("invalid_amount", "Amount must be a positive number.") unless amount.positive?

    date = params["date"].present? ? parse_date(params["date"]) : Date.current
    return error("invalid_date", "date must be a valid YYYY-MM-DD date.") unless date

    category = nil
    if params["category"].present?
      category = resolve_family_record(:category, params["category"])
      return error("category_not_found", "No category found matching '#{params["category"]}'. Use get_categories to list them.") unless category
    end

    merchant = nil
    if params["merchant"].present?
      merchant = resolve_family_record(:merchant, params["merchant"])
      return error("merchant_not_found", "No merchant found matching '#{params["merchant"]}'.") unless merchant
    end

    tags = []
    Array(params["tags"]).each do |tag_value|
      tag = resolve_family_record(:tag, tag_value)
      return error("tag_not_found", "No tag found matching '#{tag_value}'. Use get_tags to list them.") unless tag
      tags << tag
    end

    signed_amount = params["nature"] == "income" ? -amount.abs : amount.abs

    entry = account.entries.new(
      name: params["name"].to_s.strip,
      date: date,
      amount: signed_amount,
      currency: params["currency"].presence || account.currency,
      notes: params["notes"].presence,
      entryable_type: "Transaction",
      entryable_attributes: {
        category_id: category&.id,
        merchant_id: merchant&.id,
        tag_ids: tags.map(&:id)
      }.compact
    )

    if entry.save
      entry.sync_account_later
      entry.lock_saved_attributes!
      entry.transaction.lock_attr!(:tag_ids) if tags.any?

      { success: true, transaction: serialize_entry(entry), message: "Transaction '#{entry.name}' created in #{account.name}." }
    else
      error("validation_failed", entry.errors.full_messages.join("; "))
    end
  end

  private
    def writable_accounts
      @writable_accounts ||= family.accounts.visible.writable_by(user).to_a
    end

    def serialize_entry(entry)
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
