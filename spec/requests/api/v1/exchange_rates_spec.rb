# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Exchange Rates', type: :request do
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
      display_key: key,
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      display_key: key,
      scopes: [],
      source: 'web'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }
  let(:from) { 'EUR' }
  let(:to) { 'USD' }
  let(:date) { nil }

  path '/api/v1/exchange_rate' do
    get 'Look up an exchange rate' do
      description 'Retrieve a currency-to-currency exchange rate for a date. Same-currency lookups return 1.0 without a provider lookup.'
      tags 'Exchange Rates'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :from, in: :query, required: true,
                description: 'Source currency code',
                schema: { type: :string }
      parameter name: :to, in: :query, required: true,
                description: 'Destination currency code',
                schema: { type: :string }
      parameter name: :date, in: :query, required: false,
                description: 'ISO 8601 date. Defaults to today.',
                schema: { type: :string, format: :date }

      response '200', 'exchange rate retrieved' do
        schema '$ref' => '#/components/schemas/ExchangeRateResponse'

        before do
          allow(ExchangeRate).to receive(:find_or_fetch_rate).and_return(OpenStruct.new(rate: 1.2))
        end

        run_test!
      end

      response '400', 'invalid request' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:from) { 'NOPE' }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'exchange rate not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow(ExchangeRate).to receive(:find_or_fetch_rate).and_return(nil)
        end

        run_test!
      end
    end
  end
end
