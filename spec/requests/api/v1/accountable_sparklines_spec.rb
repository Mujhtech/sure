# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Accountable Sparklines', type: :request do
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
      scopes: %w[read],
      source: 'mobile'
    )
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

  path '/api/v1/accountable_sparklines/{accountable_type}' do
    parameter name: :accountable_type, in: :path, required: true,
              description: 'Account type, for example depository, credit_card, investment, crypto, loan.',
              schema: { type: :string }

    get 'Retrieve account type aggregate series' do
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
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

      let(:accountable_type) { 'depository' }
      let(:period) { 'last_30_days' }

      response '200', 'account type series returned' do
        schema '$ref' => '#/components/schemas/AccountableSparklineResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '404', 'unknown account type' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:accountable_type) { 'not_real' }

        run_test!
      end

      response '422', 'invalid date' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:start_date) { '06/01/2026' }

        run_test!
      end
    end
  end
end
