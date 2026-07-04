# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 MCP', type: :request do
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

  let(:other_user) do
    family.users.create!(
      email: 'other-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'MCP Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'MCP Read Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:application) do
    Doorkeeper::Application.create!(
      name: 'Claude',
      redirect_uri: 'https://claude.ai/callback',
      confidential: false
    )
  end

  let!(:token) do
    Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: application,
      resource_owner_id: user.id,
      scopes: 'read_write',
      expires_in: 1.year
    )
  end

  let!(:other_user_token) do
    Doorkeeper::AccessToken.create!( # pipelock:ignore
      application: application,
      resource_owner_id: other_user.id,
      scopes: 'read_write',
      expires_in: 1.year
    )
  end

  path '/api/v1/mcp' do
    get 'Retrieve MCP settings' do
      tags 'MCP'
      description 'Returns the MCP endpoint URL and the current user’s connected non-mobile OAuth clients. Token values are never returned.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'MCP settings retrieved' do
        schema '$ref' => '#/components/schemas/McpSettingsResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end
  end

  path '/api/v1/mcp/tokens/{token_id}' do
    parameter name: :token_id, in: :path, type: :integer, required: true, description: 'Doorkeeper OAuth access token ID'

    delete 'Revoke an MCP OAuth token' do
      tags 'MCP'
      description 'Revokes a non-mobile OAuth access token owned by the current user.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:token_id) { token.id }

      response '200', 'MCP token revoked' do
        schema '$ref' => '#/components/schemas/McpTokenRevokeResponse'

        run_test!
      end

      response '404', 'MCP token not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:token_id) { other_user_token.id }

        run_test!
      end
    end
  end
end
