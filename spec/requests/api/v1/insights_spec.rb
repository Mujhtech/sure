# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Insights', type: :request do
  let(:family) do
    Family.create!(name: 'Insights API Family', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y')
  end
  let(:user) do
    family.users.create!(
      email: 'insights-api@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      preferences: { 'preview_features_enabled' => true }
    )
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: 'Insights API Docs Key', key: key, scopes: %w[read_write], source: 'mobile')
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:id) do
    family.insights.create!(
      insight_type: 'idle_cash',
      priority: 'low',
      status: 'active',
      title: 'Cash is waiting',
      body: 'This balance has been idle for a while.',
      generated_at: Time.current,
      dedup_key: 'docs-idle-cash'
    ).id
  end

  path '/api/v1/insights' do
    get 'List proactive financial insights' do
      tags 'Insights'
      description 'Returns visible insights in priority order and marks new insights as read after building the response.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :mark_read, in: :query, required: false, schema: { type: :boolean, default: true },
                description: 'Set to false for previews that must preserve unread state.'

      response '200', 'insights returned' do
        schema '$ref' => '#/components/schemas/InsightsResponse'
        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        run_test!
      end
    end
  end

  path '/api/v1/insights/{id}/dismiss' do
    patch 'Dismiss an insight' do
      tags 'Insights'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :id, in: :path, type: :string, format: :uuid

      response '200', 'insight dismissed' do
        schema type: :object, required: %w[insight], properties: {
          insight: { type: :object, required: %w[id status], properties: {
            id: { type: :string, format: :uuid }, status: { type: :string, enum: %w[dismissed] }
          } }
        }
        run_test!
      end
    end
  end

  path '/api/v1/insights/{id}/undismiss' do
    patch 'Restore a dismissed insight' do
      tags 'Insights'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :id, in: :path, type: :string, format: :uuid

      response '200', 'insight restored as read' do
        before { family.insights.find(id).dismiss! }
        run_test!
      end
    end
  end

  path '/api/v1/insights/refresh' do
    post 'Queue insight regeneration' do
      tags 'Insights'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '202', 'generation queued' do
        run_test!
      end
    end
  end
end
