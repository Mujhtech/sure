# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 MFA', type: :request do
  let(:family) do
    Family.create!(
      name: 'API MFA Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-mfa@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'admin',
      onboarded_at: Time.current
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'MFA Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'MFA Read Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/mfa' do
    get 'Show MFA state' do
      tags 'Security'
      description 'Returns TOTP/WebAuthn MFA state without exposing secrets or stored backup code digests.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'MFA state returned' do
        schema '$ref' => '#/components/schemas/MfaResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end
    end

    delete 'Disable MFA' do
      tags 'Security'
      description 'Disables TOTP MFA and removes registered WebAuthn credentials for the current user.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'MFA disabled' do
        schema '$ref' => '#/components/schemas/MfaMutationResponse'

        before do
          user.setup_mfa!
          user.enable_mfa!
        end

        run_test!
      end

      response '403', 'forbidden - requires read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end
  end

  path '/api/v1/mfa/setup' do
    post 'Start TOTP MFA setup' do
      tags 'Security'
      description 'Creates a pending TOTP secret and returns provisioning data for native authenticator enrollment.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '201', 'MFA setup started' do
        schema '$ref' => '#/components/schemas/MfaSetupResponse'

        run_test!
      end

      response '422', 'MFA already enabled' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          user.setup_mfa!
          user.enable_mfa!
        end

        run_test!
      end
    end
  end

  path '/api/v1/mfa/verify' do
    post 'Verify TOTP MFA setup' do
      tags 'Security'
      description 'Verifies the pending TOTP setup code, enables MFA, and returns plaintext backup codes once.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[code],
        properties: {
          code: { type: :string }
        }
      }

      let(:body) do
        user.setup_mfa!
        { code: ROTP::TOTP.new(user.otp_secret, issuer: 'Sure Finances').now }
      end

      response '200', 'MFA enabled' do
        schema '$ref' => '#/components/schemas/MfaVerifyResponse'

        run_test!
      end

      response '422', 'invalid or missing setup code' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { code: 'invalid' } }

        run_test!
      end
    end
  end
end
