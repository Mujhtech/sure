# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Accounts', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to document the runtime insufficient-scope response.
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: %w[write],
      source: 'web'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:checking_account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Checking Account',
      balance: 1500.50,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:savings_account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Savings Account',
      balance: 10000.00,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:credit_card) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Credit Card',
      balance: -500.00,
      currency: 'USD',
      accountable: CreditCard.create!
    )
  end

  path '/api/v1/accounts' do
    get 'List accounts' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :include_disabled, in: :query, type: :boolean, required: false,
                description: 'Include disabled accounts in the response. Defaults to false.'

      response '200', 'accounts listed' do
        schema '$ref' => '#/components/schemas/AccountCollection'

        run_test!
      end

      response '200', 'accounts paginated' do
        schema '$ref' => '#/components/schemas/AccountCollection'

        let(:page) { 1 }
        let(:per_page) { 2 }

        run_test!
      end
    end
  end

  path '/api/v1/accounts/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Account ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve an account' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :include_disabled, in: :query, type: :boolean, required: false,
                description: 'Allow retrieving a disabled account. Defaults to false.'

      let(:id) { checking_account.id }

      response '200', 'account retrieved' do
        schema '$ref' => '#/components/schemas/AccountDetail'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { checking_account.id }
        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { checking_account.id }
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/accounts/{id}/series' do
    parameter name: :id, in: :path, required: true, description: 'Account ID',
              schema: { type: :string, format: :uuid }

    get 'Retrieve account balance series' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :view, in: :query, required: false,
                schema: { type: :string, enum: %w[balance cash_balance holdings_balance] },
                description: 'Balance series view. Defaults to balance.'
      parameter name: :period, in: :query, required: false,
                schema: { type: :string, enum: Period::PERIODS.keys },
                description: 'Preset period key. Ignored when start_date or end_date is supplied.'
      parameter name: :start_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Custom series start date. ISO 8601 only.'
      parameter name: :end_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Custom series end date. ISO 8601 only.'
      parameter name: :interval, in: :query, required: false,
                schema: { type: :string, enum: [ '1 day', '1 week', '1 month' ] },
                description: 'Series interval override.'

      let(:id) { checking_account.id }
      let(:period) { 'last_30_days' }

      response '200', 'account series returned' do
        schema '$ref' => '#/components/schemas/AccountSeriesResponse'

        run_test!
      end

      response '422', 'invalid series view' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:view) { 'market_value' }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/accounts/{id}/unlink' do
    parameter name: :id, in: :path, required: true, description: 'Account ID',
              schema: { type: :string, format: :uuid }

    delete 'Unlink an account provider' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      description 'Disconnect provider links from an account while keeping the account, its balances, transactions, and holdings available as manual data.'
      produces 'application/json'

      let(:id) { credit_card.id }

      before do
        plaid_item = family.plaid_items.create!(
          access_token: 'access-sandbox',
          plaid_id: 'plaid-docs-item',
          name: 'Plaid Docs Item'
        )
        plaid_account = plaid_item.plaid_accounts.create!(
          plaid_id: 'plaid-docs-account',
          name: 'Linked Credit Card',
          plaid_type: 'credit',
          current_balance: 500,
          currency: 'USD'
        )
        credit_card.update!(plaid_account: plaid_account)
      end

      response '200', 'account unlinked' do
        schema '$ref' => '#/components/schemas/AccountDetail'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'account is not linked' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { checking_account.id }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/accounts/{account_id}/sharing' do
    parameter name: :account_id, in: :path, required: true, description: 'Account ID',
              schema: { type: :string, format: :uuid }

    let(:account_id) { checking_account.id }

    get 'Retrieve account sharing state' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'account sharing retrieved' do
        schema '$ref' => '#/components/schemas/AccountSharingResponse'

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:account_id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update account sharing' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Account owners can grant or revoke family member access. Shared users can only update their own include_in_finances preference.'

      let!(:family_member) do
        family.users.create!(
          email: 'family-member@example.com',
          password: 'password123',
          password_confirmation: 'password123'
        )
      end

      let(:member_api_key) do
        key = ApiKey.generate_secure_key
        ApiKey.create!(
          user: family_member,
          name: 'Member API Docs Key',
          key: key,
          scopes: %w[read_write],
          source: 'mobile'
        )
      end

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          sharing: {
            type: :object,
            properties: {
              include_in_finances: {
                type: :boolean,
                description: 'For shared users: whether this account is included in their finances.'
              },
              members: {
                type: :array,
                description: 'For account owners: desired sharing changes.',
                items: {
                  type: :object,
                  properties: {
                    user_id: { type: :string, format: :uuid },
                    shared: { type: :boolean },
                    permission: { type: :string, enum: %w[full_control read_write read_only] }
                  },
                  required: %w[user_id shared]
                }
              }
            }
          }
        },
        required: %w[sharing]
      }

      let(:body) do
        {
          sharing: {
            members: [
              { user_id: family_member.id, shared: true, permission: 'read_only' }
            ]
          }
        }
      end

      response '200', 'account sharing updated' do
        schema '$ref' => '#/components/schemas/AccountSharingResponse'

        run_test!
      end

      response '200', 'shared user finance inclusion updated' do
        schema '$ref' => '#/components/schemas/AccountSharingResponse'

        let(:'X-Api-Key') { member_api_key.plain_key }
        let(:body) { { sharing: { include_in_finances: false } } }

        before do
          checking_account.share_with!(family_member, permission: 'read_only')
        end

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '403', 'shared user cannot update member access' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { member_api_key.plain_key }
        let(:body) do
          {
            sharing: {
              members: [
                { user_id: family_member.id, shared: true, permission: 'full_control' }
              ]
            }
          }
        end

        before do
          checking_account.share_with!(family_member, permission: 'read_write')
        end

        run_test!
      end
    end
  end
end
