# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Debug Logs', type: :request do
  let(:support_family) do
    Family.create!(
      name: 'Support Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:family) do
    Family.create!(
      name: 'Customer Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:support_user) do
    support_family.users.create!(
      email: 'support@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'super_admin'
    )
  end

  let(:admin_user) do
    family.users.create!(
      email: 'admin@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'admin'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: support_user,
      name: 'Debug Logs Docs Key',
      key: key,
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:admin_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: admin_user,
      name: 'Non Super Admin Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:account) do
    family.accounts.create!(
      owner: admin_user,
      name: 'Checking Account',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let!(:debug_log) do
    DebugLogEntry.create!(
      category: 'security_price_fetch',
      level: 'warn',
      message: 'Could not fetch prices',
      source: 'Security::Price::Importer',
      provider_key: 'twelve_data',
      family: family,
      account: account,
      user: admin_user,
      metadata: { ticker: 'AAPL' }
    )
  end

  path '/api/v1/debug_logs' do
    get 'List debug logs' do
      tags 'Debug Logs'
      description 'Lists diagnostic debug log entries. Requires a read-capable credential owned by a super admin.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :per_page, in: :query, type: :integer, required: false
      parameter name: :category, in: :query, type: :string, required: false
      parameter name: :level, in: :query, required: false,
                schema: { type: :string, enum: %w[debug info warn error] }
      parameter name: :source, in: :query, type: :string, required: false
      parameter name: :provider_key, in: :query, type: :string, required: false
      parameter name: :family_id, in: :query, type: :string, format: :uuid, required: false
      parameter name: :account_id, in: :query, type: :string, format: :uuid, required: false
      parameter name: :user_id, in: :query, type: :string, format: :uuid, required: false
      parameter name: :account_provider_id, in: :query, type: :string, format: :uuid, required: false
      parameter name: :start_date, in: :query, schema: { type: :string, format: :date }, required: false
      parameter name: :end_date, in: :query, schema: { type: :string, format: :date }, required: false

      response '200', 'debug logs listed' do
        schema '$ref' => '#/components/schemas/DebugLogCollection'

        let(:provider_key) { 'twelve_data' }

        run_test!
      end

      response '403', 'forbidden for non-super-admin' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { admin_api_key.plain_key }

        run_test!
      end
    end
  end

  path '/api/v1/debug_logs/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get 'Retrieve a debug log' do
      tags 'Debug Logs'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { debug_log.id }

      response '200', 'debug log retrieved' do
        schema '$ref' => '#/components/schemas/DebugLogResponse'

        run_test!
      end

      response '404', 'debug log not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
