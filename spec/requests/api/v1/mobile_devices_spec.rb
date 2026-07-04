# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Mobile Devices', type: :request do
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
      name: 'Mobile Devices Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Mobile Devices Read Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:mobile_device) do
    user.mobile_devices.create!(
      device_id: 'docs-ios-device',
      device_name: 'Docs iPhone',
      device_type: 'ios',
      os_version: '18.0',
      app_version: '1.4.0',
      last_seen_at: Time.current
    )
  end

  path '/api/v1/mobile_devices' do
    get 'List mobile devices' do
      tags 'Mobile Devices'
      description 'Returns mobile devices registered to the current user, including active status and active-token counts. Raw device identifiers and token values are never returned.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'mobile devices returned' do
        schema '$ref' => '#/components/schemas/MobileDeviceCollection'

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

  path '/api/v1/mobile_devices/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, description: 'Mobile device ID'

    get 'Show mobile device' do
      tags 'Mobile Devices'
      description 'Returns one mobile device registered to the current user.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { mobile_device.id }

      response '200', 'mobile device returned' do
        schema '$ref' => '#/components/schemas/MobileDevice'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end

      response '404', 'not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }
        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end

    delete 'Revoke mobile device tokens' do
      tags 'Mobile Devices'
      description 'Revokes all active access tokens for the selected mobile device without deleting device metadata.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { mobile_device.id }

      response '200', 'mobile device tokens revoked' do
        schema '$ref' => '#/components/schemas/MobileDeviceRevokeResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

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
