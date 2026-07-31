# frozen_string_literal: true

class Api::V1::TransactionsController < Api::V1::BaseController
  include Pagy::Backend

  # Ensure proper scope authorization for read vs write access
  before_action :ensure_read_scope, only: [ :index, :show, :duplicate_candidates ]
  before_action :ensure_write_scope, only: [
    :create, :update, :destroy, :bulk_update, :bulk_delete,
    :merge_duplicate, :dismiss_duplicate, :mark_as_recurring, :unlock, :convert_to_trade, :update_tags
  ]
  before_action :set_transaction, only: [
    :show, :update, :destroy, :duplicate_candidates,
    :merge_duplicate, :dismiss_duplicate, :mark_as_recurring, :unlock, :convert_to_trade, :update_tags
  ]
  before_action :ensure_transaction_account_writable, only: [
    :destroy, :merge_duplicate, :dismiss_duplicate, :mark_as_recurring, :unlock, :convert_to_trade
  ]
  before_action :ensure_transaction_account_annotatable, only: [ :update, :update_tags ]

  def index
    family = current_resource_owner.family
    accessible_account_ids = family.accounts
      .accessible_by(current_resource_owner)
      .where.not(status: "pending_deletion")
      .select(:id)
    transactions_query = family.transactions
      .joins(:entry).where(entries: { account_id: accessible_account_ids })

    # Apply filters
    transactions_query = apply_filters(transactions_query)

    # Apply search
    transactions_query = apply_search(transactions_query) if params[:search].present?

    # Include necessary associations for efficient queries
    transactions_query = transactions_query.includes(
      { entry: :account },
      { entry: { child_entries: :entryable } },
      :category, :merchant, :tags,
      attachments_attachments: :blob,
      transfer_as_outflow: { inflow_transaction: { entry: :account } },
      transfer_as_inflow: { outflow_transaction: { entry: :account } }
    ).reverse_chronological

    # Handle pagination with Pagy
    @pagy, @transactions = pagy(
      transactions_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @family_currency = family.currency
    @transaction_exchange_rates = transaction_exchange_rates_for(@transactions, @family_currency)

    # Make per_page available to the template
    @per_page = safe_per_page_param

    # Rails will automatically use app/views/api/v1/transactions/index.json.jbuilder
    render :index

  rescue => e
    Rails.logger.error "TransactionsController#index error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def show
    @family_currency = current_resource_owner.family.currency
    @transaction_exchange_rates = transaction_exchange_rates_for([ @transaction ], @family_currency)

    # Rails will automatically use app/views/api/v1/transactions/show.json.jbuilder
    render :show

  rescue => e
    Rails.logger.error "TransactionsController#show error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family

    # Validate account_id is present
    unless account_id_param.present?
      render json: {
        error: "validation_failed",
        message: "Account ID is required",
        errors: [ "Account ID is required" ]
      }, status: :unprocessable_entity
      return
    end

    if idempotency_source_param.present? && idempotency_external_id.blank?
      render json: {
        error: "validation_failed",
        message: "Source requires external_id",
        errors: [ "Source requires external_id" ]
      }, status: :unprocessable_entity
      return
    end

    account = family.accounts.writable_by(current_resource_owner).find(account_id_param)

    if idempotency_key_requested? && (existing_entry = existing_idempotent_entry(account))
      return render_existing_idempotent_entry(existing_entry)
    end

    @entry = account.entries.new(entry_params_for_create)

    if @entry.save
      @entry.sync_account_later
      @entry.lock_saved_attributes!
      @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?

      @transaction = @entry.transaction
      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Transaction could not be created",
        errors: @entry.errors.full_messages
      }, status: :unprocessable_entity
    end

  rescue ActiveRecord::RecordNotUnique
    if idempotency_key_requested? && account && (existing_entry = existing_idempotent_entry(account))
      render_existing_idempotent_entry(existing_entry)
    else
      raise
    end
  rescue => e
    Rails.logger.error "TransactionsController#create error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def update
    if @entry.split_child?
      render json: { error: "validation_failed", message: "Split child transactions cannot be edited directly. Use the split editor." }, status: :unprocessable_entity
      return
    end

    if @entry.split_parent? && split_financial_fields_changed?
      render json: { error: "validation_failed", message: "Split parent amount, date, and type cannot be changed directly. Use the split editor." }, status: :unprocessable_entity
      return
    end

    Entry.transaction do
      if @entry.update(entry_params_for_update)
        # Handle tags separately - only when explicitly provided in the request
        # This allows clearing tags with tag_ids: [] while preserving tags when not specified
        if tags_provided?
          @entry.transaction.tag_ids = family_scoped_tag_ids(transaction_params[:tag_ids] || [])
          @entry.transaction.save!
          @entry.transaction.lock_attr!(:tag_ids) if @entry.transaction.tags.any?
        end

        @entry.sync_account_later
        @entry.lock_saved_attributes!

        @transaction = @entry.transaction
        render :show
      else
        render json: {
          error: "validation_failed",
          message: "Transaction could not be updated",
          errors: @entry.errors.full_messages
        }, status: :unprocessable_entity
        raise ActiveRecord::Rollback
      end
    end

  rescue => e
    Rails.logger.error "TransactionsController#update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def destroy
    if @entry.split_child?
      render json: { error: "validation_failed", message: "Split child transactions cannot be deleted individually." }, status: :unprocessable_entity
      return
    end

    @entry.destroy!
    @entry.sync_account_later

    render json: {
      message: "Transaction deleted successfully"
    }, status: :ok

  rescue => e
    Rails.logger.error "TransactionsController#destroy error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def bulk_update
    permitted = bulk_update_params
    entry_ids = normalized_entry_ids(permitted[:entry_ids])

    if entry_ids.empty?
      render_validation_error("entry_ids is required")
      return
    end

    entries = writable_transaction_entries.excluding_split_parents.where(id: entry_ids)
    matched_count = entries.count
    updated_count = entries.bulk_update!(permitted, update_tags: bulk_update_tags_provided?)

    render json: {
      message: "#{updated_count} transactions updated",
      requested_count: entry_ids.size,
      matched_count: matched_count,
      updated_count: updated_count,
      skipped_count: entry_ids.size - matched_count
    }, status: :ok

  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence.presence || e.message)
  rescue ActionController::ParameterMissing => e
    render_validation_error(e.message)
  rescue => e
    Rails.logger.error "TransactionsController#bulk_update error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def bulk_delete
    permitted = bulk_delete_params
    entry_ids = normalized_entry_ids(permitted[:entry_ids])

    if entry_ids.empty?
      render_validation_error("entry_ids is required")
      return
    end

    entries = writable_transaction_entries.where(parent_entry_id: nil)
    destroyed = entries.destroy_by(id: entry_ids)
    destroyed.map(&:account).uniq.each(&:sync_later)

    render json: {
      message: "#{destroyed.count} transactions deleted",
      requested_count: entry_ids.size,
      deleted_count: destroyed.count,
      skipped_count: entry_ids.size - destroyed.count
    }, status: :ok

  rescue ActionController::ParameterMissing => e
    render_validation_error(e.message)
  rescue => e
    Rails.logger.error "TransactionsController#bulk_delete error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def duplicate_candidates
    unless @transaction.pending?
      render_validation_error("Transaction is not pending")
      return
    end

    limit = safe_duplicate_candidates_limit
    offset = safe_duplicate_candidates_offset
    candidates = @transaction.pending_duplicate_candidates(limit: limit + 1, offset: offset)
                             .includes(:account, entryable: [ :category, :merchant ])
                             .to_a
    has_more = candidates.size > limit

    render json: {
      duplicate_candidates: candidates.first(limit).map { |entry| duplicate_candidate_json(entry) },
      pagination: {
        limit: limit,
        offset: offset,
        has_more: has_more
      }
    }, status: :ok

  rescue => e
    Rails.logger.error "TransactionsController#duplicate_candidates error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def merge_duplicate
    posted_entry_id = duplicate_merge_posted_entry_id

    if posted_entry_id.present?
      posted_entry = find_eligible_posted_duplicate_entry(posted_entry_id)

      unless posted_entry
        render_validation_error("posted_entry_id is invalid")
        return
      end

      store_manual_duplicate_match!(posted_entry)
    end

    if @transaction.merge_with_duplicate!
      render json: { message: "Duplicate transaction merged successfully" }, status: :ok
    else
      render_validation_error("Transaction does not have a mergeable duplicate suggestion")
    end

  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed,
         ActiveRecord::Deadlocked, ActiveRecord::LockWaitTimeout => e
    Rails.logger.error "TransactionsController#merge_duplicate error: #{e.message}"
    render_validation_error("Duplicate transaction could not be merged")
  rescue => e
    Rails.logger.error "TransactionsController#merge_duplicate error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def dismiss_duplicate
    if @transaction.dismiss_duplicate_suggestion!
      render json: { message: "Duplicate suggestion dismissed successfully" }, status: :ok
    else
      render_validation_error("Transaction does not have a duplicate suggestion")
    end

  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "TransactionsController#dismiss_duplicate error: #{e.message}"
    render_validation_error("Duplicate suggestion could not be dismissed")
  rescue => e
    Rails.logger.error "TransactionsController#dismiss_duplicate error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def update_tags
    tag_ids = family_scoped_tag_ids(transaction_tag_ids)

    @transaction.tag_ids = tag_ids
    @entry.lock_saved_attributes!
    @entry.mark_user_modified!
    @transaction.lock_attr!(:tag_ids)
    @entry.sync_account_later
    @transaction.reload

    render :show
  rescue ActionController::ParameterMissing => e
    render_validation_error(e.message)
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence.presence || e.message)
  rescue => e
    Rails.logger.error "TransactionsController#update_tags error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def mark_as_recurring
    existing = current_resource_owner.family.recurring_transactions.find_by(
      account_id: @entry.account_id,
      merchant_id: @transaction.merchant_id,
      name: @transaction.merchant_id.present? ? nil : @entry.name,
      currency: @entry.currency,
      manual: true
    )

    if existing
      render json: {
        error: "conflict",
        message: "Recurring transaction already exists",
        recurring_transaction_id: existing.id
      }, status: :conflict
      return
    end

    @recurring_transaction = RecurringTransaction.create_from_transaction(@transaction)
    render "api/v1/recurring_transactions/show", status: :created

  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Recurring transaction could not be created",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "TransactionsController#mark_as_recurring error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def convert_to_trade
    unless @entry.account.investment?
      render_validation_error("Transaction must belong to an investment account")
      return
    end

    if @entry.excluded?
      render_validation_error("Transaction has already been converted or excluded")
      return
    end

    security = resolve_conversion_security
    return if performed?

    qty, price = conversion_qty_and_price
    return if performed?

    requested_activity_label = trade_conversion_params[:investment_activity_label].presence
    is_sell = requested_activity_label == "Sell" || (requested_activity_label.blank? && @entry.amount.negative?)
    activity_label = requested_activity_label || (is_sell ? "Sell" : "Buy")
    signed_qty = is_sell ? -qty : qty
    trade_amount = qty * price
    signed_amount = is_sell ? -trade_amount : trade_amount

    Entry.transaction do
      new_entry = @entry.account.entries.create!(
        name: trade_conversion_params[:trade_name].presence || Trade.build_name(is_sell ? "sell" : "buy", qty, security.ticker),
        date: @entry.date,
        amount: signed_amount,
        currency: @entry.currency,
        notes: conversion_note,
        entryable: Trade.new(
          security: security,
          qty: signed_qty,
          price: price,
          currency: @entry.currency,
          investment_activity_label: activity_label
        )
      )

      new_entry.lock_saved_attributes!
      new_entry.mark_user_modified!
      @entry.update!(excluded: true)

      @trade = new_entry.trade
      @entry = new_entry
    end

    render template: "api/v1/trades/show", status: :created
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved => e
    record = e.respond_to?(:record) ? e.record : nil
    render json: {
      error: "validation_failed",
      message: "Transaction could not be converted to a trade",
      errors: record&.errors&.full_messages || [ e.message ]
    }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error "TransactionsController#convert_to_trade error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  def unlock
    @entry.unlock_for_sync!
    @transaction.reload

    render :show

  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence.presence || e.message)
  rescue => e
    Rails.logger.error "TransactionsController#unlock error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")

    render json: {
      error: "internal_server_error",
      message: "An unexpected error occurred"
    }, status: :internal_server_error
  end

  private

    def set_transaction
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      family = current_resource_owner.family
      @transaction = family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find(params[:id])
      @entry = @transaction.entry
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Transaction not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_transaction_account_writable
      return if transaction_account_writable?

      render json: {
        error: "forbidden",
        message: "You are not authorized to modify this transaction"
      }, status: :forbidden
    end

    def ensure_transaction_account_annotatable
      return if transaction_account_annotatable?

      render json: {
        error: "forbidden",
        message: "You are not authorized to annotate this transaction"
      }, status: :forbidden
    end

    def transaction_account_writable?
      @entry.account.permission_for(current_resource_owner).in?(%i[owner full_control])
    end

    def transaction_account_annotatable?
      @entry.account.permission_for(current_resource_owner).in?(%i[owner full_control read_write])
    end

    def apply_filters(query)
      # Account filtering
      if params[:account_id].present?
        query = query.where(entries: { account_id: params[:account_id] })
      end

      if params[:account_ids].present?
        account_ids = Array(params[:account_ids])
        query = query.where(entries: { account_id: account_ids })
      end

      # Category filtering
      if params[:category_id].present?
        query = query.where(category_id: params[:category_id])
      end

      if params[:category_ids].present?
        category_ids = Array(params[:category_ids])
        query = query.where(category_id: category_ids)
      end

      # Merchant filtering
      if params[:merchant_id].present?
        query = query.where(merchant_id: params[:merchant_id])
      end

      if params[:merchant_ids].present?
        merchant_ids = Array(params[:merchant_ids])
        query = query.where(merchant_id: merchant_ids)
      end

      # Date range filtering
      if params[:start_date].present?
        query = query.where("entries.date >= ?", Date.parse(params[:start_date]))
      end

      if params[:end_date].present?
        query = query.where("entries.date <= ?", Date.parse(params[:end_date]))
      end

      # Amount filtering
      if params[:min_amount].present?
        min_amount = params[:min_amount].to_f
        query = query.where("entries.amount >= ?", min_amount)
      end

      if params[:max_amount].present?
        max_amount = params[:max_amount].to_f
        query = query.where("entries.amount <= ?", max_amount)
      end

      # Tag filtering
      if params[:tag_ids].present?
        tag_ids = Array(params[:tag_ids])
        query = query.where(
          id: query.joins(:tags).where(tags: { id: tag_ids }).distinct.select(:id)
        )
      end

      # Transaction type filtering (income/expense)
      if params[:type].present?
        case params[:type].downcase
        when "income"
          query = query.where("entries.amount < 0")
        when "expense"
          query = query.where("entries.amount > 0")
        end
      end

      query
    end

    def apply_search(query)
      search_term = "%#{params[:search]}%"

      query
        .left_joins(:merchant)
        .where(
          "entries.name ILIKE ? OR entries.notes ILIKE ? OR merchants.name ILIKE ?",
          search_term, search_term, search_term
        )
    end

    def transaction_params
      params.require(:transaction).permit(
        :date, :amount, :name, :description, :notes, :currency,
        :category_id, :merchant_id, :nature, tag_ids: []
      )
    end

    def bulk_update_params
      params.require(:bulk_update)
            .permit(:date, :notes, :name, :category_id, :merchant_id, entry_ids: [], tag_ids: [])
    end

    def bulk_delete_params
      params.require(:bulk_delete).permit(entry_ids: [])
    end

    def trade_conversion_params
      source = params[:trade_conversion].present? ? params.require(:trade_conversion) : params
      source.permit(
        :security_id,
        :ticker,
        :custom_ticker,
        :exchange_operating_mic,
        :qty,
        :price,
        :investment_activity_label,
        :trade_name
      )
    end

    def normalized_entry_ids(entry_ids)
      Array.wrap(entry_ids).filter_map { |entry_id| entry_id.to_s.presence }.uniq
    end

    def writable_transaction_entries
      writable_account_ids = current_resource_owner.family.accounts.writable_by(current_resource_owner).select(:id)

      current_resource_owner.family.entries
                            .where(account_id: writable_account_ids)
                            .where(entryable_type: "Transaction")
    end

    def duplicate_merge_posted_entry_id
      params.dig(:duplicate, :posted_entry_id).presence || params[:posted_entry_id].presence
    end

    def find_eligible_posted_duplicate_entry(entry_id)
      return nil unless valid_uuid?(entry_id)

      conditions = Transaction::PENDING_PROVIDERS.map { |provider| "(transactions.extra -> '#{provider}' ->> 'pending')::boolean IS NOT TRUE" }

      @entry.account.entries
            .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
            .where(id: entry_id)
            .where(currency: @entry.currency)
            .where.not(id: @entry.id)
            .where(conditions.join(" AND "))
            .first
    end

    def store_manual_duplicate_match!(posted_entry)
      @transaction.update!(
        extra: (@transaction.extra || {}).deep_dup.merge(
          "potential_posted_match" => {
            "entry_id" => posted_entry.id,
            "reason" => "manual_match",
            "posted_amount" => posted_entry.amount.to_s,
            "confidence" => "high",
            "detected_at" => Date.current.to_s
          }
        )
      )
    end

    def duplicate_candidate_json(entry)
      transaction = entry.transaction
      amount_cents = amount_cents_for_entry(entry)

      {
        entry_id: entry.id,
        transaction_id: transaction.id,
        date: entry.date,
        name: entry.name,
        amount: entry.amount_money.format,
        amount_cents: amount_cents,
        signed_amount_cents: entry.classification == "income" ? amount_cents : -amount_cents,
        currency: entry.currency,
        account: {
          id: entry.account.id,
          name: entry.account.name,
          account_type: entry.account.accountable_type&.underscore
        },
        category: transaction.category && {
          id: transaction.category.id,
          name: transaction.category.name,
          color: transaction.category.color,
          icon: transaction.category.lucide_icon
        },
        merchant: transaction.merchant && {
          id: transaction.merchant.id,
          name: transaction.merchant.name
        }
      }
    end

    def amount_cents_for_entry(entry)
      money = entry.amount_money
      (money.amount * money.currency.minor_unit_conversion).round(0).to_i.abs
    end

    def transaction_exchange_rates_for(transactions, target_currency)
      Array(transactions).each_with_object({}) do |transaction, rates|
        entry = transaction.entry
        from_currency = entry.currency
        next if from_currency == target_currency

        key = [ from_currency, entry.date ]
        rates[key] ||= begin
          rate = ExchangeRate.find_or_fetch_rate(from: from_currency, to: target_currency, date: entry.date)
          if rate.nil?
            Rails.logger.warn("No exchange rate found for #{from_currency}/#{target_currency} on #{entry.date}, using 1")
          end
          rate&.rate || 1
        end
      end
    end

    def resolve_conversion_security
      conversion = trade_conversion_params

      security = if conversion[:security_id].present? && conversion[:security_id] != "__custom__"
        Security.find_by(id: conversion[:security_id])
      elsif conversion[:ticker].present?
        parsed = Security.parse_combobox_id(conversion[:ticker])
        if parsed[:ticker].blank?
          render_validation_error("ticker is invalid")
          return
        end

        Security::Resolver.new(
          parsed[:ticker].strip,
          exchange_operating_mic: parsed[:exchange_operating_mic] || conversion[:exchange_operating_mic].presence,
          country_code: current_resource_owner.family.country,
          price_provider: parsed[:price_provider]
        ).resolve
      elsif conversion[:custom_ticker].present?
        Security::Resolver.new(
          conversion[:custom_ticker].strip,
          exchange_operating_mic: conversion[:exchange_operating_mic].presence,
          country_code: current_resource_owner.family.country
        ).resolve
      end

      unless security
        render_validation_error("security_id, ticker, or custom_ticker is required")
        return
      end

      security
    end

    def conversion_qty_and_price
      amount = @entry.amount.abs
      qty = trade_conversion_params[:qty].present? ? trade_conversion_params[:qty].to_d.abs : nil
      price = trade_conversion_params[:price].present? ? trade_conversion_params[:price].to_d : nil

      if qty.nil? && price.nil?
        render_validation_error("qty or price is required")
        return
      elsif qty.nil? && price.present? && price.positive?
        qty = (amount / price).round(6)
      elsif price.nil? && qty.present? && qty.positive?
        price = (amount / qty).round(4)
      end

      if qty.nil? || qty <= 0 || price.nil? || price <= 0
        render_validation_error("qty and price must be greater than 0")
        return
      end

      [ qty, price ]
    end

    def conversion_note
      "Converted from transaction #{@entry.name} on #{@entry.date.to_date.iso8601}"
    end

    def safe_duplicate_candidates_limit
      limit = params[:limit].to_i
      return 10 if limit <= 0

      [ limit, 50 ].min
    end

    def safe_duplicate_candidates_offset
      [ params[:offset].to_i, 0 ].max
    end

    def account_id_param
      params.dig(:transaction, :account_id).presence
    end

    def entry_params_for_create
      entry_params = {
        name: transaction_params[:name] || transaction_params[:description],
        date: transaction_params[:date],
        amount: calculate_signed_amount,
        currency: transaction_params[:currency] || current_resource_owner.family.currency,
        notes: transaction_params[:notes],
        entryable_type: "Transaction",
        entryable_attributes: {
          category_id: transaction_params[:category_id],
          merchant_id: transaction_params[:merchant_id],
          tag_ids: transaction_params[:tag_ids] || []
        }
      }
      if idempotency_key_requested?
        entry_params[:external_id] = idempotency_external_id
        entry_params[:source] = idempotency_source
      end

      entry_params.compact
    end

    def entry_params_for_update
      return annotation_entry_params_for_update unless transaction_account_writable?

      permitted = transaction_params
      entry_params = {
        name: permitted[:name] || permitted[:description],
        date: permitted[:date],
        notes: permitted[:notes],
        entryable_attributes: {
          id: @entry.entryable_id,
          category_id: permitted[:category_id],
          merchant_id: permitted[:merchant_id]
          # Note: tag_ids handled separately in update action to distinguish
          # "not provided" from "explicitly set to empty"
        }.compact_blank
      }

      # Only update amount if provided
      if permitted[:amount].present?
        entry_params[:amount] = calculate_signed_amount
      end

      entry_params.compact
    end

    def annotation_entry_params_for_update
      permitted = transaction_params
      entry_params = {}
      entry_params[:notes] = permitted[:notes] if permitted.key?(:notes)

      entryable_attributes = {}
      entryable_attributes[:category_id] = permitted[:category_id] if permitted.key?(:category_id)
      entryable_attributes[:merchant_id] = permitted[:merchant_id] if permitted.key?(:merchant_id)

      if entryable_attributes.any?
        entryable_attributes[:id] = @entry.entryable_id
        entry_params[:entryable_attributes] = entryable_attributes
      end

      entry_params
    end

    # Check if tag_ids was explicitly provided in the request.
    # This distinguishes between "user wants to update tags" vs "user didn't specify tags".
    def tags_provided?
      params[:transaction].key?(:tag_ids)
    end

    def family_scoped_tag_ids(tag_ids)
      current_resource_owner.family.tags.where(id: normalized_entry_ids(tag_ids)).pluck(:id)
    end

    def transaction_tag_ids
      transaction_params = params.require(:transaction)
      raise ActionController::ParameterMissing, :tag_ids unless transaction_params.key?(:tag_ids)

      Array.wrap(transaction_params[:tag_ids]).filter_map { |tag_id| tag_id.to_s.presence }.uniq
    end

    def bulk_update_tags_provided?
      bulk_update = params[:bulk_update]
      bulk_update.respond_to?(:key?) && bulk_update.key?(:tag_ids)
    end

    def split_financial_fields_changed?
      params.dig(:transaction, :amount).present? ||
        params.dig(:transaction, :date).present? ||
        params.dig(:transaction, :nature).present?
    end

    def idempotency_key_requested?
      idempotency_external_id.present?
    end

    def idempotency_external_id
      idempotency_param_value(:external_id)
    end

    def idempotency_source
      idempotency_source_param.presence || "api"
    end

    def idempotency_source_param
      idempotency_param_value(:source)
    end

    def idempotency_param_value(key)
      value = params.dig(:transaction, key)
      value.to_s.presence if value.is_a?(String) || value.is_a?(Numeric)
    end

    def existing_idempotent_entry(account)
      account.entries.find_by(
        external_id: idempotency_external_id,
        source: idempotency_source
      )
    end

    def render_existing_idempotent_entry(entry)
      unless entry.entryable.is_a?(Transaction)
        render json: {
          error: "validation_failed",
          message: "External ID already exists for a non-transaction entry",
          errors: [ "External ID already exists for a non-transaction entry" ]
        }, status: :unprocessable_entity
        return
      end

      @entry = entry
      @transaction = entry.transaction
      render :show, status: :ok
    end

    def calculate_signed_amount
      amount = transaction_params[:amount].to_f
      nature = transaction_params[:nature]

      case nature&.downcase
      when "income", "inflow"
        -amount.abs  # Income is negative
      when "expense", "outflow"
        amount.abs   # Expense is positive
      else
        amount       # Use as provided
      end
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      case per_page
      when 1..100
        per_page
      else
        25  # Default
      end
    end
end
