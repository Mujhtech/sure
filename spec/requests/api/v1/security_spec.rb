# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Security', type: :request do
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
      name: 'Security Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Security Read Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:webauthn_credential) do
    user.update!(otp_required: true, otp_backup_codes: [ 'digest' ])
    user.webauthn_credentials.create!(
      nickname: 'Docs Passkey',
      credential_id: "docs-credential-#{SecureRandom.hex(4)}",
      public_key: 'public-key',
      sign_count: 0,
      transports: [ 'internal' ]
    )
  end

  let!(:sso_identity) do
    user.oidc_identities.create!(
      provider: 'openid_connect',
      uid: "docs-uid-#{SecureRandom.hex(4)}",
      info: { email: user.email },
      last_authenticated_at: Time.current
    )
  end

  path '/api/v1/security' do
    get 'Show security overview' do
      tags 'Security'
      description 'Returns current-user security settings for mobile settings screens: MFA status, passkeys, linked SSO identities, available SSO providers, and local password state.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'security overview returned' do
        schema '$ref' => '#/components/schemas/SecurityOverviewResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end
    end
  end

  path '/api/v1/webauthn_credentials/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: 'WebAuthn credential ID'

    delete 'Remove WebAuthn credential' do
      tags 'Security'
      description 'Removes a WebAuthn credential from the current user. MFA must be enabled.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { webauthn_credential.id }

      response '200', 'credential removed' do
        schema '$ref' => '#/components/schemas/WebauthnCredentialDeleteResponse'

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

  path '/api/v1/webauthn_credentials/options' do
    post 'Create WebAuthn registration options' do
      tags 'Security'
      description 'Creates short-lived WebAuthn registration options for native passkey/security-key enrollment. Requires enabled MFA and read_write scope.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'registration options returned' do
        schema '$ref' => '#/components/schemas/WebauthnRegistrationOptionsResponse'

        run_test!
      end

      response '403', 'forbidden - requires read_write scope or enabled MFA' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end
  end

  path '/api/v1/webauthn_credentials' do
    post 'Register WebAuthn credential' do
      tags 'Security'
      description 'Verifies a native WebAuthn registration response using a challenge_id from the options endpoint and stores the credential.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[challenge_id credential],
        properties: {
          challenge_id: { type: :string, format: :uuid },
          webauthn_credential: {
            type: :object,
            properties: {
              nickname: { type: :string }
            }
          },
          credential: {
            type: :object,
            description: 'Serialized PublicKeyCredential registration response from the native platform.'
          }
        }
      }

      let(:body) { { challenge_id: SecureRandom.uuid, credential: {} } }

      response '201', 'credential registered' do
        schema '$ref' => '#/components/schemas/WebauthnCredentialCreateResponse'

        before do
          allow_any_instance_of(Api::V1::WebauthnCredentialsController)
            .to receive(:webauthn_credential_payload)
            .and_return({ 'id' => 'docs-credential', 'response' => {} })
          verified_credential = Struct.new(:id, :public_key, :sign_count).new(
            "docs-created-credential-#{SecureRandom.hex(4)}",
            'public-key',
            0
          )
          relying_party = instance_double('WebAuthn::RelyingParty', verify_registration: verified_credential)
          allow_any_instance_of(Api::V1::WebauthnCredentialsController)
            .to receive(:webauthn_relying_party)
            .and_return(relying_party)
          allow(Rails.cache).to receive(:read).and_return('docs-challenge')
          allow(Rails.cache).to receive(:delete)
        end

        run_test!
      end

      response '422', 'missing or expired challenge' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        run_test!
      end
    end
  end

  path '/api/v1/sso_identities/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: 'SSO identity ID'

    delete 'Unlink SSO identity' do
      tags 'Security'
      description 'Unlinks a current-user SSO identity. The last SSO identity cannot be unlinked while the user has no local password.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { sso_identity.id }

      response '200', 'SSO identity unlinked' do
        schema '$ref' => '#/components/schemas/SsoIdentityDeleteResponse'

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
