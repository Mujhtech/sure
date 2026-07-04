# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 LLM Usage', type: :request do
  let(:family) do
    Family.create!(
      name: 'API LLM Usage Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-llm-usage@example.com',
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
      name: 'LLM Usage Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }
  let(:start_date) { 7.days.ago.to_date.iso8601 }
  let(:end_date) { Date.current.iso8601 }
  let(:limit) { 25 }

  path '/api/v1/llm_usage' do
    get 'Show LLM usage' do
      tags 'AI'
      description 'Returns date-filtered LLM usage statistics and recent usage rows for the authenticated user family.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :start_date, in: :query, required: false, schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false, schema: { type: :string, format: :date }
      parameter name: :limit, in: :query, required: false, schema: { type: :integer, minimum: 1, maximum: 100, default: 100 }

      response '200', 'LLM usage returned' do
        schema '$ref' => '#/components/schemas/LlmUsageResponse'

        before do
          family.llm_usages.create!(
            provider: 'openai',
            model: 'gpt-4.1',
            operation: 'chat',
            prompt_tokens: 20,
            completion_tokens: 10,
            total_tokens: 30,
            estimated_cost: 0.0012,
            created_at: 1.day.ago
          )
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end

      response '422', 'invalid date filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:start_date) { 'not-a-date' }

        run_test!
      end
    end
  end
end
