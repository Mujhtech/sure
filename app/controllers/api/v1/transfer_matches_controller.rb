# frozen_string_literal: true

class Api::V1::TransferMatchesController < Api::V1::BaseController
  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: :create
  before_action :set_transaction
  before_action :ensure_source_account_writable, only: :create

  def show
    render json: {
      transaction: transaction_side_payload(@transaction),
      target_accounts: target_accounts_payload,
      transfer_match_candidates: candidate_payloads
    }, status: :ok
  rescue ArgumentError => e
    render_validation_error(e.message)
  end

  def create
    @transfer = build_transfer_match

    Transfer.transaction do
      @transfer.save!
      apply_transfer_kinds!
    end

    @transfer.sync_account_later

    render "api/v1/transfers/show", status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: "Transfer match could not be created",
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  end

  private
    def set_transaction
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:transaction_id])

      @transaction = current_resource_owner.family.transactions
        .joins(entry: :account)
        .merge(Account.accessible_by(current_resource_owner))
        .find(params[:transaction_id])
      @entry = @transaction.entry
    end

    def ensure_source_account_writable
      return if writable_accounts_scope.exists?(@entry.account_id)

      render json: {
        error: "forbidden",
        message: "You are not authorized to match this transaction"
      }, status: :forbidden
    end

    def build_transfer_match
      case transfer_match_method
      when "new"
        build_transfer_with_missing_side
      when "existing", "match"
        build_transfer_with_existing_entry
      else
        raise ActiveRecord::RecordInvalid.new(invalid_transfer("method must be one of: existing, new"))
      end
    end

    def transfer_match_method
      method = transfer_match_params[:method].presence
      return method if method.present?
      return "new" if transfer_match_params[:target_account_id].present?
      return "existing" if transfer_match_params[:matched_entry_id].present?

      nil
    end

    def build_transfer_with_missing_side
      target_account_id = transfer_match_params[:target_account_id]
      raise ActiveRecord::RecordNotFound unless valid_uuid?(target_account_id)

      target_account = writable_accounts_scope.where.not(id: @entry.account_id).find(target_account_id)
      missing_transaction = Transaction.new(
        entry: target_account.entries.build(
          amount: @entry.amount * -1,
          currency: @entry.currency,
          date: @entry.date,
          name: "Transfer to #{@entry.amount.negative? ? @entry.account.name : target_account.name}",
          user_modified: true
        )
      )

      transfer = Transfer.find_or_initialize_by(
        inflow_transaction: @entry.amount.positive? ? missing_transaction : @transaction,
        outflow_transaction: @entry.amount.positive? ? @transaction : missing_transaction
      )
      transfer.status = "confirmed"
      transfer
    end

    def build_transfer_with_existing_entry
      matched_entry_id = transfer_match_params[:matched_entry_id]
      raise ActiveRecord::RecordNotFound unless valid_uuid?(matched_entry_id)

      target_entry = current_resource_owner.family.entries
        .joins(:account)
        .merge(Account.writable_by(current_resource_owner).visible)
        .where(entryable_type: "Transaction")
        .where.not(account_id: @entry.account_id)
        .find(matched_entry_id)

      transfer = Transfer.find_or_initialize_by(
        inflow_transaction: @entry.amount.negative? ? @transaction : target_entry.transaction,
        outflow_transaction: @entry.amount.negative? ? target_entry.transaction : @transaction
      )
      transfer.status = "confirmed"
      transfer
    end

    def apply_transfer_kinds!
      destination_account = @transfer.inflow_transaction.entry.account
      outflow_kind = Transfer.kind_for_account(destination_account)
      outflow_attrs = { kind: outflow_kind }

      if outflow_kind == "investment_contribution"
        category = destination_account.family.investment_contributions_category
        outflow_attrs[:category] = category if category.present? && @transfer.outflow_transaction.category_id.blank?
      end

      @transfer.outflow_transaction.update!(outflow_attrs)
      @transfer.inflow_transaction.update!(kind: "funds_movement")
    end

    def transfer_match_params
      params.require(:transfer_match).permit(:method, :matched_entry_id, :target_account_id)
    end

    def candidate_payloads
      transaction_ids = transfer_match_candidate_rows.flat_map do |candidate|
        [ candidate.inflow_transaction_id, candidate.outflow_transaction_id ]
      end.uniq
      transactions = current_resource_owner.family.transactions
        .includes(entry: :account)
        .where(id: transaction_ids)
        .index_by(&:id)

      transfer_match_candidate_rows.filter_map do |candidate|
        inflow_transaction = transactions[candidate.inflow_transaction_id]
        outflow_transaction = transactions[candidate.outflow_transaction_id]
        next unless candidate_visible?(inflow_transaction, outflow_transaction)

        {
          date_diff: candidate.date_diff.to_i,
          rejected: candidate.rejected_transfer_id.present?,
          inflow_transaction: transaction_side_payload(inflow_transaction),
          outflow_transaction: transaction_side_payload(outflow_transaction)
        }
      end
    end

    def transfer_match_candidate_rows
      @transfer_match_candidate_rows ||= begin
        filters = @entry.amount.negative? ? { inflow_transaction_id: @transaction.id } : { outflow_transaction_id: @transaction.id }
        current_resource_owner.family.transfer_match_candidates(
          date_window: transfer_match_date_window,
          **filters
        )
      end
    end

    def candidate_visible?(inflow_transaction, outflow_transaction)
      return false unless inflow_transaction && outflow_transaction

      accessible_account_ids.include?(inflow_transaction.entry.account_id) &&
        accessible_account_ids.include?(outflow_transaction.entry.account_id)
    end

    def target_accounts_payload
      writable_accounts_scope.where.not(id: @entry.account_id).alphabetically.map do |account|
        {
          id: account.id,
          name: account.name,
          account_type: account.accountable_type&.underscore,
          currency: account.currency
        }
      end
    end

    def transaction_side_payload(transaction)
      entry = transaction.entry
      money = entry.amount_money

      {
        id: transaction.id,
        entry_id: entry.id,
        date: entry.date.iso8601,
        amount: money.format,
        amount_cents: money_to_minor_units(money),
        currency: entry.currency,
        name: entry.name,
        kind: transaction.kind,
        account: {
          id: entry.account.id,
          name: entry.account.name,
          account_type: entry.account.accountable_type&.underscore
        }
      }
    end

    def transfer_match_date_window
      Integer(params[:date_window].presence || 30)
    rescue ArgumentError, TypeError
      raise ArgumentError, "date_window must be an integer"
    end

    def accessible_account_ids
      @accessible_account_ids ||= current_resource_owner.family.accounts
        .accessible_by(current_resource_owner)
        .pluck(:id)
    end

    def writable_accounts_scope
      current_resource_owner.family.accounts.writable_by(current_resource_owner).visible
    end

    def money_to_minor_units(money)
      (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
    end

    def invalid_transfer(message)
      Transfer.new.tap { |transfer| transfer.errors.add(:base, message) }
    end
end
