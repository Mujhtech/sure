# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Account Types', type: :request do
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

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.new(
      user: user,
      name: 'API Docs Write Key',
      key: key,
      scopes: %w[write],
      source: 'web'
    ).tap { |record| record.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/account_types' do
    get 'Lists account type metadata' do
      description 'Lists backend-owned account type metadata for native clients, including labels, classifications, colors, icons, subtypes, and available provider connection descriptors.'
      tags 'Accounts'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'account type metadata listed' do
        schema '$ref' => '#/components/schemas/AccountTypeCollection'
        run_test!
      end

      response '401', 'unauthorized' do
        let(:'X-Api-Key') { nil }

        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end

      response '403', 'insufficient scope' do
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        schema '$ref' => '#/components/schemas/ErrorResponse'
        run_test!
      end
    end
  end
end
