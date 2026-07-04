# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Invite Codes', type: :request do
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
      email: 'super-admin@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'super_admin'
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
      name: 'API Docs Read Key',
      key: key,
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  before do
    allow(Rails.configuration.app_mode).to receive(:self_hosted?).and_return(true)
  end

  path '/api/v1/invite_codes' do
    get 'List invite codes' do
      tags 'Invite Codes'
      description 'List self-hosted registration invite codes. Requires self-hosted mode, read scope, and a super admin user.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:'X-Api-Key') { read_only_api_key.plain_key }

      response '200', 'invite codes listed' do
        schema '$ref' => '#/components/schemas/InviteCodeCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end
    end

    post 'Create invite code' do
      tags 'Invite Codes'
      description 'Generate a new self-hosted registration invite code.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '201', 'invite code created' do
        schema '$ref' => '#/components/schemas/InviteCodeResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end
  end

  path '/api/v1/invite_codes/{id}' do
    parameter name: :id, in: :path, required: true, description: 'Invite code ID',
              schema: { type: :string, format: :uuid }

    let!(:invite_code) { InviteCode.create! }
    let(:id) { invite_code.id }

    delete 'Delete invite code' do
      tags 'Invite Codes'
      description 'Delete a self-hosted registration invite code.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'invite code deleted' do
        schema '$ref' => '#/components/schemas/SuccessMessage'

        run_test!
      end

      response '404', 'invite code not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
