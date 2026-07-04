# frozen_string_literal: true

module MobileDeltaSync
  class Serializer
    def initialize(user:)
      @user = user
    end

    def account(account)
      balance_money = account.balance_money
      cash_balance_money = account.cash_balance_money

      {
        id: account.id,
        name: account.name,
        balance: balance_money.format,
        balance_cents: cents(balance_money, signed: true),
        cash_balance: cash_balance_money.format,
        cash_balance_cents: cents(cash_balance_money, signed: true),
        currency: account.currency,
        classification: account.classification,
        account_type: account.accountable_type&.underscore,
        subtype: account.accountable&.respond_to?(:subtype) ? account.accountable.subtype : nil,
        status: account.status,
        institution_name: account.institution_name,
        institution_domain: account.institution_domain,
        exclude_from_reports: account.exclude_from_reports?,
        default: account.id == @user.default_account_id,
        transaction_default_eligible: account.eligible_for_transaction_default?,
        syncing: account.syncing?,
        linked: account.linked?,
        manual: account.manual?,
        deletable: !account.linked?,
        owner: account.owner && {
          id: account.owner.id,
          email: account.owner.email,
          display_name: account.owner.display_name,
          initials: account.owner.initials
        },
        sharing: account_sharing(account),
        created_at: account.created_at.iso8601,
        updated_at: account.updated_at.iso8601
      }
    end

    def transaction(transaction)
      entry = transaction.entry
      amount_money = entry.amount_money
      amount_cents = cents(amount_money)

      {
        id: transaction.id,
        entry_id: entry.id,
        date: entry.date,
        amount: amount_money.format,
        amount_cents: amount_cents,
        signed_amount_cents: entry.classification == "income" ? amount_cents : -amount_cents,
        currency: entry.currency,
        name: entry.name,
        notes: entry.notes,
        external_id: entry.external_id,
        source: entry.source,
        classification: entry.classification,
        pending: transaction.pending?,
        protection: {
          protected: entry.protected_from_sync?,
          reason: entry.protection_reason,
          locked_fields: entry.locked_field_names,
          user_modified: entry.user_modified?,
          import_locked: entry.import_locked?
        },
        duplicate_suggestion: nil,
        account: {
          id: entry.account.id,
          name: entry.account.name,
          account_type: entry.account.accountable_type&.underscore
        },
        category: category_summary(transaction.category),
        merchant: merchant_summary(transaction.merchant),
        tags: transaction.tags.map { |tag| tag(tag) },
        attachments: [],
        transfer: nil,
        split: split_summary(transaction),
        created_at: transaction.created_at.iso8601,
        updated_at: transaction.updated_at.iso8601
      }
    end

    def category(category)
      {
        id: category.id,
        name: category.name,
        color: category.color,
        icon: category.lucide_icon,
        lucide_icon: category.lucide_icon,
        parent_id: category.parent_id,
        parent: category.parent && {
          id: category.parent.id,
          name: category.parent.name
        },
        subcategories_count: category.subcategories.size,
        created_at: category.created_at.iso8601,
        updated_at: category.updated_at.iso8601
      }
    end

    def merchant(merchant)
      {
        id: merchant.id,
        name: merchant.name,
        type: merchant.type,
        color: merchant.respond_to?(:color) ? merchant.color : nil,
        logo_url: merchant.respond_to?(:logo_url) ? merchant.logo_url : nil,
        website_url: merchant.respond_to?(:website_url) ? merchant.website_url : nil,
        created_at: merchant.created_at.iso8601,
        updated_at: merchant.updated_at.iso8601
      }
    end

    def tag(tag)
      {
        id: tag.id,
        name: tag.name,
        color: tag.color,
        created_at: tag.created_at.iso8601,
        updated_at: tag.updated_at.iso8601
      }
    end

    private

      def cents(money, signed: false)
        amount = (money.amount * money.currency.minor_unit_conversion).round(0).to_i
        signed ? amount : amount.abs
      end

      def account_sharing(account)
        current_share = if account.account_shares.loaded?
          account.account_shares.find { |share| share.user_id == @user.id }
        else
          account.account_shares.find_by(user: @user)
        end

        {
          shared: account.shared?,
          owned_by_current_user: account.owned_by?(@user),
          current_user_permission: account.permission_for(@user),
          include_in_finances: current_share&.include_in_finances? || account.owned_by?(@user)
        }
      end

      def category_summary(category)
        return nil unless category

        {
          id: category.id,
          name: category.name,
          color: category.color,
          icon: category.lucide_icon
        }
      end

      def merchant_summary(merchant)
        return nil unless merchant

        {
          id: merchant.id,
          name: merchant.name
        }
      end

      def split_summary(transaction)
        entry = transaction.entry

        {
          parent: entry.split_parent?,
          child: entry.split_child?,
          splittable: transaction.splittable?,
          parent_entry_id: entry.split_child? ? entry.parent_entry&.id : nil,
          parent_transaction_id: entry.split_child? ? entry.parent_entry&.entryable_id : nil,
          lines: []
        }
      end
  end
end
