# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Preferences', type: :request do
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

  path '/api/v1/preferences' do
    get 'Retrieve user preferences' do
      tags 'Preferences'
      description 'Retrieve web-compatible user preference settings for dashboard, reports, transactions, appearance, and preview features.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'preferences retrieved' do
        schema '$ref' => '#/components/schemas/UserPreferencesResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end
    end

    patch 'Update user preferences' do
      tags 'Preferences'
      description 'Update dashboard, reports, transactions, appearance, and preview feature preferences. Accepts friendly nested groups or raw web preference keys.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          preferences: {
            type: :object,
            properties: {
              preview_features_enabled: { type: :boolean },
              show_split_grouped: { type: :boolean },
              dashboard_two_column: { type: :boolean },
              dashboard: {
                type: :object,
                properties: {
                  collapsed_sections: { type: :object, additionalProperties: { type: :boolean } },
                  section_order: { type: :array, items: { type: :string } },
                  section_layout: { type: :object }
                }
              },
              reports: {
                type: :object,
                properties: {
                  collapsed_sections: { type: :object, additionalProperties: { type: :boolean } },
                  section_order: { type: :array, items: { type: :string } }
                }
              },
              transactions: {
                type: :object,
                properties: {
                  collapsed_sections: { type: :object, additionalProperties: { type: :boolean } }
                }
              }
            }
          }
        },
        required: %w[preferences]
      }

      let(:body) do
        {
          preferences: {
            preview_features_enabled: true,
            show_split_grouped: false,
            dashboard_two_column: true,
            dashboard: {
              collapsed_sections: { net_worth_chart: true },
              section_order: %w[balance_sheet net_worth_chart],
              section_layout: { net_worth_chart: { height: 'tall', col_span: 'full' } }
            },
            reports: {
              collapsed_sections: { transactions_breakdown: true },
              section_order: %w[transactions_breakdown trends_insights]
            },
            transactions: {
              collapsed_sections: { filters: true }
            }
          }
        }
      end

      response '200', 'preferences updated' do
        schema '$ref' => '#/components/schemas/UserPreferencesResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '400', 'missing preferences payload' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { {} }

        run_test!
      end
    end
  end
end
