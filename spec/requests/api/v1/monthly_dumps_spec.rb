# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Monthly Dump', type: :request do
  let(:family) do
    Family.create!(
      name: 'Monthly Dump API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'monthly-dump-api@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Monthly Dump API Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }
  let(:month) { Date.current.prev_month.strftime('%Y-%m') }

  path '/api/v1/monthly_dump' do
    get 'Show a completed Monthly Dump' do
      tags 'Monthly Dump'
      description 'Returns a ten-slide-ready recap for a completed calendar month. Defaults to the latest completed month and includes privacy-safe AI-refined archetype copy with a deterministic fallback.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :month, in: :query, required: false,
                schema: { type: :string, pattern: '^\d{4}-(0[1-9]|1[0-2])$' },
                description: 'Completed calendar month in YYYY-MM format. Defaults to the previous month.'

      response '200', 'monthly dump returned' do
        schema '$ref' => '#/components/schemas/MonthlyDumpResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '422', 'month is incomplete or malformed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:month) { Date.current.strftime('%Y-%m') }

        run_test!
      end
    end
  end
end
