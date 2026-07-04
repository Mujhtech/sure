# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Currencies', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Family',
      currency: 'SGD',
      enabled_currencies: %w[USD],
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

  path '/api/v1/currencies' do
    get 'List supported currencies' do
      description 'Retrieve currency metadata for all supported currencies, or only currencies enabled for the authenticated family.'
      tags 'Currencies'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :enabled_only, in: :query, required: false,
                description: 'When true, only return family-enabled currencies.',
                schema: { type: :boolean }
      parameter name: :extra, in: :query, required: false,
                description: 'Additional currency codes to include with enabled_only=true.',
                schema: { type: :array, items: { type: :string } },
                style: :form,
                explode: true
      parameter name: :q, in: :query, required: false,
                description: 'Case-insensitive search across ISO code and name.',
                schema: { type: :string }

      response '200', 'currencies listed' do
        schema '$ref' => '#/components/schemas/CurrencyCollection'

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
    end
  end

  path '/api/v1/currencies/{id}' do
    parameter name: :id, in: :path, required: true, description: 'ISO 4217 currency code',
              schema: { type: :string }

    get 'Retrieve a currency' do
      tags 'Currencies'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { 'USD' }

      response '200', 'currency retrieved' do
        schema '$ref' => '#/components/schemas/Currency'

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

      response '404', 'currency not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { 'NOPE' }

        run_test!
      end
    end
  end
end
