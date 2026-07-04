# frozen_string_literal: true

require "set"

module MobileDeltaSync
  class Processor
    class ValidationError < StandardError; end
    class ConflictError < StandardError; end

    attr_reader :user, :family, :mobile_device, :serializer

    def initialize(user:, mobile_device:)
      @user = user
      @family = user.family
      @mobile_device = mobile_device
      @serializer = Serializer.new(user: user)
    end

    def call(cursor:, changes:)
      accepted = []
      rejected = []
      conflicts = []

      Array(changes).each do |change|
        result = process_change(change)
        case result[:status]
        when "accepted" then accepted << result
        when "conflict" then conflicts << result
        else rejected << result
        end
      end

      {
        next_cursor: next_cursor,
        accepted: accepted,
        rejected: rejected,
        conflicts: conflicts,
        changes: pull_changes(cursor)
      }
    end

    private

      def process_change(change)
        attrs = normalize_change(change)
        operation = find_or_initialize_operation(attrs)

        return operation.response_payload.symbolize_keys if operation.terminal?

        begin
          result = apply_change!(attrs)
          payload = operation_payload(attrs, "accepted", result)
          operation.update!(
            status: "accepted",
            entity_id: result[:server_entity_id] || attrs[:entity_id],
            response_payload: payload,
            processed_at: Time.current
          )
          payload
        rescue ConflictError => e
          payload = operation_payload(attrs, "conflict", message: e.message)
          operation.update!(status: "conflict", response_payload: payload, error_message: e.message, processed_at: Time.current)
          payload
        rescue ValidationError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
          message = e.respond_to?(:record) ? e.record.errors.full_messages.to_sentence : e.message
          payload = operation_payload(attrs, "rejected", message: message)
          operation.update!(status: "rejected", response_payload: payload, error_message: message, processed_at: Time.current)
          payload
        end
      end

      def normalize_change(change)
        attrs = change.to_unsafe_h if change.respond_to?(:to_unsafe_h)
        attrs ||= change.to_h
        attrs = attrs.deep_transform_keys(&:to_s)

        {
          client_change_id: attrs.fetch("client_change_id").to_s,
          entity_type: attrs.fetch("entity_type").to_s,
          entity_id: attrs["entity_id"].presence,
          operation: attrs.fetch("operation").to_s,
          base_revision: attrs["base_revision"].presence&.to_i,
          payload: (attrs["payload"] || {}).deep_transform_keys(&:to_s)
        }
      rescue KeyError => e
        raise ValidationError, "#{e.key} is required"
      end

      def find_or_initialize_operation(attrs)
        operation = MobileSyncOperation.find_or_initialize_by(
          family: family,
          client_change_id: attrs[:client_change_id]
        )

        if operation.new_record?
          operation.assign_attributes(
            user: user,
            mobile_device: mobile_device,
            entity_type: attrs[:entity_type],
            entity_id: attrs[:entity_id],
            operation: attrs[:operation],
            base_revision: attrs[:base_revision],
            request_payload: attrs[:payload],
            status: "pending"
          )
          operation.save!
        end

        operation
      end

      def apply_change!(attrs)
        raise ValidationError, "Only transaction changes are supported" unless attrs[:entity_type] == "transaction"

        check_conflict!(attrs)

        case attrs[:operation]
        when "create" then create_transaction!(attrs)
        when "update" then update_transaction!(attrs)
        when "delete" then delete_transaction!(attrs)
        else raise ValidationError, "Unsupported operation"
        end
      end

      def check_conflict!(attrs)
        return if attrs[:base_revision].blank?
        return if attrs[:entity_id].blank?

        changed = MobileSyncEvent
          .where(family: family, entity_type: attrs[:entity_type], entity_id: attrs[:entity_id])
          .where("id > ?", attrs[:base_revision])
          .exists?

        raise ConflictError, "Server changed this #{attrs[:entity_type]} after the local edit began" if changed
      end

      def create_transaction!(attrs)
        payload = attrs[:payload]
        account = writable_manual_account(payload.fetch("account_id"))
        entry = account.entries.create!(entry_attributes(payload, attrs[:client_change_id]).merge(entryable: transaction_attributes(payload)))
        lock_entry!(entry, payload)

        {
          client_entity_id: attrs[:entity_id],
          server_entity_id: entry.transaction.id,
          entity: serializer.transaction(entry.transaction)
        }
      end

      def update_transaction!(attrs)
        transaction = writable_manual_transaction(attrs[:entity_id])
        entry = transaction.entry
        payload = attrs[:payload]

        entry.update!(entry_update_attributes(payload))

        transaction.assign_attributes(transaction_update_attributes(payload))
        transaction.tag_ids = family_scoped_tag_ids(payload["tag_ids"]) if payload.key?("tag_ids")
        transaction.save!

        lock_entry!(entry, payload)

        {
          server_entity_id: transaction.id,
          entity: serializer.transaction(transaction.reload)
        }
      end

      def delete_transaction!(attrs)
        transaction = writable_manual_transaction(attrs[:entity_id])
        entry = transaction.entry
        entry.destroy!

        {
          server_entity_id: attrs[:entity_id]
        }
      end

      def entry_attributes(payload, client_change_id)
        {
          name: payload["name"].presence || payload["description"],
          date: payload.fetch("date"),
          amount: signed_amount(payload),
          currency: payload["currency"].presence || family.currency,
          notes: payload["notes"],
          external_id: client_change_id,
          source: "mobile_delta_sync"
        }.compact
      end

      def entry_update_attributes(payload)
        attrs = {}
        attrs[:name] = payload["name"].presence || payload["description"] if payload.key?("name") || payload.key?("description")
        attrs[:date] = payload["date"] if payload.key?("date")
        attrs[:amount] = signed_amount(payload) if payload.key?("amount")
        attrs[:notes] = payload["notes"] if payload.key?("notes")
        attrs.compact
      end

      def transaction_attributes(payload)
        Transaction.new(transaction_update_attributes(payload).merge(tag_ids: family_scoped_tag_ids(payload["tag_ids"])))
      end

      def transaction_update_attributes(payload)
        attrs = {}
        attrs[:category_id] = family.categories.find_by(id: payload["category_id"])&.id if payload.key?("category_id")
        attrs[:merchant_id] = family.available_merchants_for(user).find_by(id: payload["merchant_id"])&.id if payload.key?("merchant_id")
        attrs.compact
      end

      def signed_amount(payload)
        amount = BigDecimal(payload.fetch("amount").to_s)
        case payload["nature"].to_s.downcase
        when "income", "inflow"
          -amount.abs
        when "expense", "outflow"
          amount.abs
        else
          amount
        end
      rescue ArgumentError
        raise ValidationError, "amount is invalid"
      end

      def writable_manual_transaction(id)
        raise ValidationError, "entity_id is required" if id.blank?

        transaction = family.transactions
          .joins(entry: :account)
          .where(accounts: { id: family.accounts.writable_by(user).manual.select(:id) })
          .find(id)

        raise ValidationError, "Only manual account transactions can be synced from mobile" unless manual_entry?(transaction.entry)
        raise ValidationError, "Split child transactions cannot be edited from mobile delta sync" if transaction.entry.split_child?

        transaction
      end

      def writable_manual_account(id)
        raise ValidationError, "account_id is required" if id.blank?

        family.accounts.writable_by(user).manual.find(id)
      rescue ActiveRecord::RecordNotFound
        raise ValidationError, "Account is not writable or is not manual"
      end

      def manual_entry?(entry)
        entry.source.blank? || entry.source == "mobile_delta_sync"
      end

      def family_scoped_tag_ids(tag_ids)
        family.tags.where(id: Array.wrap(tag_ids).filter_map { |id| id.to_s.presence }.uniq).pluck(:id)
      end

      def lock_entry!(entry, payload)
        entry.lock_saved_attributes!
        entry.mark_user_modified!
        entry.transaction.lock_attr!(:tag_ids) if payload.key?("tag_ids") && entry.transaction.tags.any?
        entry.sync_account_later
      end

      def operation_payload(attrs, status, result = {}, message: nil)
        {
          client_change_id: attrs[:client_change_id],
          status: status,
          entity_type: attrs[:entity_type],
          operation: attrs[:operation],
          client_entity_id: result[:client_entity_id] || attrs[:entity_id],
          server_entity_id: result[:server_entity_id] || attrs[:entity_id],
          entity: result[:entity],
          message: message
        }.compact
      end

      def pull_changes(cursor)
        return full_snapshot if cursor.blank?

        revision = cursor.to_i

        events = MobileSyncEvent.where(family: family).after_revision(revision).order(:id).to_a
        entity_ids = events.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |event, memo|
          memo[event.entity_type] << event.entity_id if event.entity_id.present? && event.operation == "upsert"
        end

        {
          accounts: accounts_scope.where(id: entity_ids["account"]).map { |account| serializer.account(account) },
          transactions: transactions_scope.where(id: entity_ids["transaction"]).map { |transaction| serializer.transaction(transaction) },
          categories: family.categories.where(id: entity_ids["category"]).map { |category| serializer.category(category) },
          merchants: family.available_merchants_for(user).where(id: entity_ids["merchant"]).map { |merchant| serializer.merchant(merchant) },
          tags: family.tags.where(id: entity_ids["tag"]).map { |tag| serializer.tag(tag) },
          deleted: events.select { |event| event.operation == "delete" }.map { |event| tombstone(event) }
        }
      end

      def full_snapshot
        {
          accounts: accounts_scope.map { |account| serializer.account(account) },
          transactions: transactions_scope.map { |transaction| serializer.transaction(transaction) },
          categories: family.categories.includes(:parent, :subcategories).map { |category| serializer.category(category) },
          merchants: family.available_merchants_for(user).map { |merchant| serializer.merchant(merchant) },
          tags: family.tags.map { |tag| serializer.tag(tag) },
          deleted: []
        }
      end

      def accounts_scope
        family.accounts.accessible_by(user).historical.includes(:owner, :account_shares, :accountable).order(:name)
      end

      def transactions_scope
        accessible_account_ids = family.accounts
          .accessible_by(user)
          .where.not(status: "pending_deletion")
          .select(:id)

        family.transactions
          .joins(:entry)
          .where(entries: { account_id: accessible_account_ids })
          .includes({ entry: :account }, :category, :merchant, :tags)
          .reverse_chronological
      end

      def tombstone(event)
        {
          entity_type: event.entity_type,
          entity_id: event.entity_id,
          revision: event.revision,
          deleted_at: event.occurred_at.iso8601
        }
      end

      def next_cursor
        MobileSyncEvent.where(family: family).maximum(:id).to_i.to_s
      end
  end
end
