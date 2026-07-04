# frozen_string_literal: true

class Api::V1::TransactionCategorizationsController < Api::V1::BaseController
  BOOLEAN = ActiveModel::Type::Boolean.new
  TRANSACTION_TYPES = %w[income expense].freeze

  before_action :ensure_read_scope, only: %i[show preview_rule]
  before_action :ensure_write_scope, only: %i[create assign_entry]

  def show
    position = safe_offset_param(:position)
    group = Transaction::Grouper.strategy.call(
      accessible_categorization_entries,
      limit: 1,
      offset: position
    ).first

    render_json({
      position: position,
      all_done: group.blank?,
      total_uncategorized: total_uncategorized_count,
      categories: categories_payload,
      group: group && group_payload(group)
    })
  end

  def preview_rule
    transaction_type = normalized_transaction_type(preview_filter_params[:transaction_type])
    return if performed?

    filter = preview_filter_params[:filter].to_s.strip
    matching_entries = filter.present? ? Entry.uncategorized_matching(accessible_categorization_entries, filter, transaction_type) : []
    offset = safe_offset_param(:offset)
    limit = safe_limit_param
    entries = matching_entries.drop(offset).first(limit)

    render_json({
      filter: filter,
      transaction_type: transaction_type,
      total_matching: matching_entries.size,
      pagination: {
        limit: limit,
        offset: offset,
        has_more: matching_entries.size > offset + entries.size
      },
      categories: categories_payload,
      entries: entries.map { |entry| entry_payload(entry) }
    })
  end

  def create
    permitted = categorization_params
    entry_ids = normalized_ids(permitted[:entry_ids])
    return render_validation_error("entry_ids is required") if entry_ids.empty?

    category = find_category(permitted[:category_id])
    return if performed?

    transaction_type = normalized_transaction_type(permitted[:transaction_type])
    return if performed?

    entries = annotatable_categorization_entries.where(id: entry_ids)
    matched_count = entries.count
    updated_count = entries.bulk_update!({ category_id: category.id })
    rule_requested = BOOLEAN.cast(permitted[:create_rule])
    rule = create_rule_from_params(permitted, category, transaction_type) if rule_requested

    render_json({
      message: "#{updated_count} transactions categorized",
      requested_count: entry_ids.size,
      matched_count: matched_count,
      updated_count: updated_count,
      skipped_count: entry_ids.size - matched_count,
      category: category_payload(category),
      rule: rule_result_payload(rule_requested, rule),
      remaining: remaining_payload(permitted[:all_entry_ids], entry_ids),
      total_uncategorized: total_uncategorized_count
    })
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence.presence || e.message)
  end

  def assign_entry
    permitted = assign_entry_params
    entry = find_accessible_entry(permitted[:entry_id])
    return if performed?
    return unless ensure_entry_annotatable(entry)

    category = find_category(permitted[:category_id])
    return if performed?

    updated_count = annotatable_categorization_entries.where(id: entry.id).bulk_update!({ category_id: category.id })

    render_json({
      message: "Transaction categorized",
      entry_id: entry.id,
      transaction_id: entry.entryable_id,
      updated_count: updated_count,
      category: category_payload(category),
      remaining: remaining_payload(permitted[:all_entry_ids], [ entry.id ]),
      total_uncategorized: total_uncategorized_count
    })
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence.presence || e.message)
  end

  private

    def accessible_categorization_entries
      current_resource_owner.family.entries
                            .joins(:account)
                            .merge(Account.accessible_by(current_resource_owner))
                            .where(entryable_type: "Transaction")
                            .excluding_split_parents
    end

    def annotatable_categorization_entries
      annotatable_account_ids = current_resource_owner.family.accounts
                                                      .left_joins(:account_shares)
                                                      .where(
                                                        "accounts.owner_id = :user_id OR " \
                                                        "(account_shares.user_id = :user_id AND account_shares.permission IN (:permissions))",
                                                        user_id: current_resource_owner.id,
                                                        permissions: %w[full_control read_write]
                                                      )
                                                      .select(:id)

      current_resource_owner.family.entries
                            .where(account_id: annotatable_account_ids)
                            .where(entryable_type: "Transaction")
                            .excluding_split_parents
    end

    def total_uncategorized_count
      accessible_categorization_entries.uncategorized_transactions.count
    end

    def categories_payload
      current_resource_owner.family.categories
                            .includes(:parent, :subcategories)
                            .alphabetically
                            .map { |category| category_payload(category) }
    end

    def group_payload(group)
      {
        grouping_key: group.grouping_key,
        display_name: group.display_name,
        transaction_type: group.transaction_type,
        merchant: merchant_payload(group.merchant),
        entry_ids: group.entries.map(&:id),
        entries: group.entries.map { |entry| entry_payload(entry) }
      }
    end

    def entry_payload(entry)
      transaction = entry.entryable
      amount_cents = amount_cents_for(entry)

      {
        entry_id: entry.id,
        transaction_id: transaction.id,
        date: entry.date,
        name: entry.name,
        amount: entry.amount_money.format,
        amount_cents: amount_cents,
        signed_amount_cents: entry.classification == "income" ? amount_cents : -amount_cents,
        currency: entry.currency,
        classification: entry.classification,
        excluded: entry.excluded?,
        account: account_payload(entry.account),
        category: transaction.category && category_payload(transaction.category),
        merchant: merchant_payload(transaction.merchant)
      }
    end

    def account_payload(account)
      {
        id: account.id,
        name: account.name,
        account_type: account.accountable_type&.underscore
      }
    end

    def category_payload(category)
      {
        id: category.id,
        name: category.name,
        color: category.color,
        icon: category.lucide_icon,
        parent: category.parent && {
          id: category.parent.id,
          name: category.parent.name
        },
        subcategories_count: category.subcategories.size
      }
    end

    def merchant_payload(merchant)
      return nil unless merchant

      {
        id: merchant.id,
        name: merchant.name
      }
    end

    def amount_cents_for(entry)
      money = entry.amount_money
      (money.amount * money.currency.minor_unit_conversion).round(0).to_i.abs
    end

    def remaining_payload(all_entry_ids, removed_entry_ids)
      remaining_ids = normalized_ids(all_entry_ids) - normalized_ids(removed_entry_ids)
      entries = uncategorized_entries_for(remaining_ids)

      {
        entry_ids: entries.map(&:id),
        entries: entries.map { |entry| entry_payload(entry) },
        all_done: entries.empty?
      }
    end

    def uncategorized_entries_for(entry_ids)
      return [] if entry_ids.empty?

      accessible_categorization_entries
        .where(id: entry_ids)
        .uncategorized_transactions
        .includes(:account, entryable: :merchant)
        .order(entries: { date: :desc })
        .to_a
    end

    def create_rule_from_params(permitted, category, transaction_type)
      grouping_key = permitted[:grouping_key].to_s.strip
      return nil if grouping_key.blank?

      Rule.create_from_grouping(
        current_resource_owner.family,
        grouping_key,
        category,
        transaction_type: transaction_type
      )
    end

    def rule_result_payload(requested, rule)
      payload = {
        requested: requested,
        created: rule.present?
      }

      if rule
        payload.merge!(
          id: rule.id,
          name: rule.name,
          resource_type: rule.resource_type
        )
      elsif requested
        payload[:error] = "rule_creation_failed"
      end

      payload
    end

    def find_accessible_entry(entry_id)
      return render_validation_error("entry_id is required") if entry_id.blank?
      raise ActiveRecord::RecordNotFound unless valid_uuid?(entry_id)

      accessible_categorization_entries.find(entry_id)
    end

    def find_category(category_id)
      return render_validation_error("category_id is required") if category_id.blank?
      raise ActiveRecord::RecordNotFound unless valid_uuid?(category_id)

      current_resource_owner.family.categories.find(category_id)
    end

    def ensure_entry_annotatable(entry)
      return true if entry.account.permission_for(current_resource_owner).in?(%i[owner full_control read_write])

      render_json({
        error: "forbidden",
        message: "You are not authorized to annotate this transaction"
      }, status: :forbidden)
      false
    end

    def normalized_transaction_type(value)
      transaction_type = value.to_s.presence
      return nil if transaction_type.blank?
      return transaction_type if transaction_type.in?(TRANSACTION_TYPES)

      render_validation_error("transaction_type must be one of: #{TRANSACTION_TYPES.join(", ")}")
      nil
    end

    def normalized_ids(values)
      Array.wrap(values).filter_map { |value| value.to_s.presence }.uniq
    end

    def safe_offset_param(key)
      [ params[key].to_i, 0 ].max
    end

    def safe_limit_param
      limit = params[:limit].to_i
      return 100 if limit <= 0

      [ limit, 250 ].min
    end

    def categorization_params
      source = params[:categorization]
      source = params unless source.respond_to?(:permit)

      source.permit(:category_id, :grouping_key, :transaction_type, :create_rule, :position, entry_ids: [], all_entry_ids: [])
    end

    def assign_entry_params
      source = params[:assignment]
      source = params unless source.respond_to?(:permit)

      source.permit(:entry_id, :category_id, :position, all_entry_ids: [])
    end

    def preview_filter_params
      source = params[:rule_preview]
      source = params unless source.respond_to?(:permit)

      source.permit(:filter, :transaction_type)
    end
end
