# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Admin SSO Providers', type: :request do
  let(:family) do
    Family.create!(
      name: 'Admin SSO Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'super-admin-sso@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'super_admin'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Admin SSO Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Admin SSO Read Docs Key',
      key: key,
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:sso_provider) do
    SsoProvider.create!(
      strategy: 'google_oauth2',
      name: 'google_docs',
      label: 'Sign in with Google',
      enabled: true,
      client_id: 'client-id',
      client_secret: 'client-secret',
      settings: { default_role: 'member' }
    )
  end

  path '/api/v1/admin/sso_providers' do
    get 'List admin SSO providers' do
      tags 'Admin SSO Providers'
      description 'Lists database-managed SSO providers and read-only runtime providers. Requires a read-capable credential owned by a super admin.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:'X-Api-Key') { read_only_api_key.plain_key }

      response '200', 'SSO providers listed' do
        schema '$ref' => '#/components/schemas/AdminSsoProviderCollection'

        before do
          sso_provider
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end
    end

    post 'Create admin SSO provider' do
      tags 'Admin SSO Providers'
      description 'Creates a database-managed SSO provider. Client secrets are accepted but never returned.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :sso_provider_params, in: :body, schema: { '$ref' => '#/components/schemas/AdminSsoProviderCreateRequest' }

      let(:sso_provider_params) do
        {
          sso_provider: {
            strategy: 'github',
            name: 'github_docs',
            label: 'GitHub',
            enabled: true,
            client_id: 'github-client',
            client_secret: 'github-secret',
            settings: { default_role: 'member' }
          }
        }
      end

      response '201', 'SSO provider created' do
        schema '$ref' => '#/components/schemas/AdminSsoProviderResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end
  end

  path '/api/v1/admin/sso_providers/{id}' do
    parameter name: :id, in: :path, required: true, description: 'SSO provider ID',
              schema: { type: :string, format: :uuid }

    let(:id) { sso_provider.id }

    get 'Retrieve admin SSO provider' do
      tags 'Admin SSO Providers'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:'X-Api-Key') { read_only_api_key.plain_key }

      response '200', 'SSO provider retrieved' do
        schema '$ref' => '#/components/schemas/AdminSsoProviderResponse'

        run_test!
      end

      response '404', 'SSO provider not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update admin SSO provider' do
      tags 'Admin SSO Providers'
      description 'Updates a database-managed SSO provider. Blank client_secret values preserve the existing secret.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :sso_provider_params, in: :body, schema: { '$ref' => '#/components/schemas/AdminSsoProviderUpdateRequest' }

      let(:sso_provider_params) do
        {
          sso_provider: {
            label: 'Updated Google',
            client_secret: '',
            settings: { default_role: 'admin' }
          }
        }
      end

      response '200', 'SSO provider updated' do
        schema '$ref' => '#/components/schemas/AdminSsoProviderResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end

    delete 'Delete admin SSO provider' do
      tags 'Admin SSO Providers'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'SSO provider deleted' do
        schema '$ref' => '#/components/schemas/SuccessMessage'

        run_test!
      end
    end
  end

  path '/api/v1/admin/sso_providers/{id}/toggle' do
    parameter name: :id, in: :path, required: true, description: 'SSO provider ID',
              schema: { type: :string, format: :uuid }

    let(:id) { sso_provider.id }

    patch 'Toggle admin SSO provider' do
      tags 'Admin SSO Providers'
      description 'Enables or disables a database-managed SSO provider.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'SSO provider toggled' do
        schema '$ref' => '#/components/schemas/AdminSsoProviderResponse'

        run_test!
      end
    end
  end

  path '/api/v1/admin/sso_providers/{id}/test_connection' do
    parameter name: :id, in: :path, required: true, description: 'SSO provider ID',
              schema: { type: :string, format: :uuid }

    let(:id) { sso_provider.id }

    post 'Test admin SSO provider connection' do
      tags 'Admin SSO Providers'
      description 'Runs the same SSO configuration validation used by the web admin UI. Requires a read_write credential owned by a super admin.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'SSO provider connection tested' do
        schema '$ref' => '#/components/schemas/AdminSsoProviderTestResponse'

        run_test!
      end
    end
  end
end
