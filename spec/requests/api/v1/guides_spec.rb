# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Guides', type: :request do
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
      name: 'Guides Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/guide' do
    get 'Retrieve onboarding guide' do
      tags 'Guides'
      description 'Returns the same onboarding guide content used by the web settings guide page as Markdown for native rendering.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'guide retrieved' do
        schema '$ref' => '#/components/schemas/GuideResponse'

        run_test!
      end
    end
  end
end
