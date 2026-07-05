# frozen_string_literal: true

# Returns the family's balance sheet data (net worth, assets, liabilities)
# with all monetary values converted to the family's primary currency.
class Api::V1::BalanceSheetController < Api::V1::BaseController
  before_action :ensure_read_scope

  # GET /api/v1/balance_sheet
  # Returns net worth, total assets, and total liabilities as Money objects.
  def show
    family = current_resource_owner.family
    balance_sheet = family.balance_sheet

    render json: {
      currency: family.currency,
      net_worth: balance_sheet.net_worth_money.as_json,
      assets: balance_sheet.assets.total_money.as_json,
      liabilities: balance_sheet.liabilities.total_money.as_json,
      asset_groups: account_group_payloads(balance_sheet.assets.account_groups),
      liability_groups: account_group_payloads(balance_sheet.liabilities.account_groups)
    }
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def account_group_payloads(groups)
      groups.map do |group|
        included_accounts = included_group_accounts(group)

        {
          name: group.name,
          color: group.color,
          account_type: group.key,
          classification: group.classification,
          total: group.total_money.as_json,
          weight: group.weight.to_f,
          accounts: included_accounts.map { |account| account_payload(account, group) }
        }
      end
    end

    def included_group_accounts(group)
      group.accounts
        .select { |account| account.respond_to?(:included_in_finances?) ? account.included_in_finances? : true }
        .reject { |account| account.respond_to?(:exclude_from_reports?) && account.exclude_from_reports? }
    end

    def account_payload(account, group)
      {
        id: account.id,
        name: account.name,
        currency: account.currency,
        balance: account.balance_money.as_json,
        converted_balance: Money.new(account.converted_balance, group.currency).as_json,
        classification: group.classification,
        account_type: group.key,
        weight: group.total.zero? ? 0 : (account.converted_balance / group.total.to_d * 100).to_f
      }
    end
end
