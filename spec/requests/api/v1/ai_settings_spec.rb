# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 AI Settings', type: :request do
  let(:family) do
    Family.create!(
      name: 'API AI Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-ai@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: 'admin',
      ai_enabled: true,
      onboarded_at: Time.current
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'AI Settings Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  before do
    allow(Rails.configuration.app_mode).to receive(:self_hosted?).and_return(false)
  end

  path '/api/v1/ai_settings' do
    get 'Show AI settings and prompts' do
      tags 'AI'
      description 'Returns effective AI availability, assistant type, visible prompt instructions, and built-in assistant function names.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'AI settings returned' do
        schema '$ref' => '#/components/schemas/AiSettingsResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end
    end
  end
end
