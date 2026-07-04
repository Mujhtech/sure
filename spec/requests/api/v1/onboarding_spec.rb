# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Onboarding', type: :request do
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
      password_confirmation: 'password123',
      role: 'admin'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Onboarding Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Onboarding Read Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  before do
    allow(Rails.configuration.app_mode).to receive(:self_hosted?).and_return(false)
  end

  path '/api/v1/onboarding' do
    get 'Show onboarding state' do
      tags 'Onboarding'
      description 'Returns mobile onboarding state, current user/family setup values, trial status, and picker options.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'onboarding state returned' do
        schema '$ref' => '#/components/schemas/OnboardingResponse'

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

  path '/api/v1/onboarding/profile' do
    patch 'Update onboarding profile step' do
      tags 'Onboarding'
      description 'Updates first/last name and, for admins, initial family name, moniker, and country.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              first_name: { type: :string },
              last_name: { type: :string }
            }
          },
          family: {
            type: :object,
            properties: {
              name: { type: :string },
              country: { type: :string },
              moniker: { type: :string, enum: %w[Family Group] }
            }
          }
        }
      }

      let(:body) do
        {
          user: { first_name: 'Mobile', last_name: 'User' },
          family: { name: 'Mobile Family', country: 'US', moniker: 'Family' }
        }
      end

      response '200', 'profile step updated' do
        schema '$ref' => '#/components/schemas/OnboardingResponse'

        run_test!
      end

      response '403', 'forbidden - requires read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end
  end

  path '/api/v1/onboarding/preferences' do
    patch 'Update onboarding preferences step' do
      tags 'Onboarding'
      description 'Updates theme and family locale, currency, and date format, then marks onboarding preferences complete.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              theme: { type: :string, enum: %w[system light dark] },
              locale: { type: :string }
            }
          },
          family: {
            type: :object,
            properties: {
              locale: { type: :string },
              currency: { type: :string },
              date_format: { type: :string }
            }
          }
        }
      }

      let(:body) do
        {
          user: { theme: 'dark', locale: 'en' },
          family: { locale: 'en', currency: 'USD', date_format: '%m-%d-%Y' }
        }
      end

      response '200', 'preferences step updated' do
        schema '$ref' => '#/components/schemas/OnboardingResponse'

        run_test!
      end
    end
  end

  path '/api/v1/onboarding/goals' do
    patch 'Update onboarding goals step' do
      tags 'Onboarding'
      description 'Stores selected onboarding goals and marks onboarding complete.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[user],
        properties: {
          user: {
            type: :object,
            required: %w[goals],
            properties: {
              goals: {
                type: :array,
                items: { type: :string }
              }
            }
          }
        }
      }

      let(:body) { { user: { goals: %w[cashflow budgeting] } } }

      response '200', 'goals step updated' do
        schema '$ref' => '#/components/schemas/OnboardingResponse'

        run_test!
      end
    end
  end

  path '/api/v1/onboarding/complete' do
    post 'Complete onboarding' do
      tags 'Onboarding'
      description 'Marks onboarding complete without changing selected goals. Useful when native UX skips optional steps.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'onboarding completed' do
        schema '$ref' => '#/components/schemas/OnboardingResponse'

        run_test!
      end
    end
  end

  path '/api/v1/onboarding/start_trial' do
    post 'Start trial' do
      tags 'Onboarding'
      description 'Starts the offline trial subscription when available. Disabled for self-hosted instances.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'trial started or onboarding state returned' do
        schema '$ref' => '#/components/schemas/OnboardingResponse'

        run_test!
      end

      response '422', 'trial already used' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          family.create_subscription!(status: 'trialing', trial_ends_at: 10.days.from_now)
        end

        run_test!
      end
    end
  end
end
