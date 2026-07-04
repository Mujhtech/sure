# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 API Keys', type: :request do
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
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Read Only Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/api_keys' do
    get 'List API keys' do
      tags 'API Keys'
      description 'Lists active API keys for the current user. Secret key values are never returned from this endpoint.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'API keys returned' do
        schema '$ref' => '#/components/schemas/PersonalApiKeyCollection'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end
    end

    post 'Create API key' do
      tags 'API Keys'
      description 'Creates a mobile-sourced API key. The plain key value is returned only in this create response.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[api_key],
        properties: {
          api_key: {
            type: :object,
            required: %w[name scopes],
            properties: {
              name: { type: :string },
              scopes: { type: :string, enum: %w[read read_write] }
            }
          }
        }
      }

      let(:body) do
        {
          api_key: {
            name: 'Native API Key',
            scopes: 'read'
          }
        }
      end

      response '201', 'API key created' do
        schema '$ref' => '#/components/schemas/PersonalApiKeyCreateResponse'

        run_test!
      end

      response '403', 'forbidden - requires read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '422', 'validation failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { api_key: { name: '', scopes: 'read' } } }

        run_test!
      end
    end
  end

  path '/api/v1/api_keys/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: 'API key ID'

    get 'Show API key' do
      tags 'API Keys'
      description 'Returns API key metadata. Secret key values are not returned.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { api_key.id }

      response '200', 'API key returned' do
        schema '$ref' => '#/components/schemas/PersonalApiKeyResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '404', 'not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }
        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end

    delete 'Revoke API key' do
      tags 'API Keys'
      description 'Revokes an active API key for the current user.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { read_only_api_key.id }

      response '200', 'API key revoked' do
        schema '$ref' => '#/components/schemas/PersonalApiKeyRevokeResponse'

        run_test!
      end

      response '403', 'forbidden - requires read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '404', 'not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
