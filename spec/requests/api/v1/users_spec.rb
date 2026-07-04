# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Users', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Family',
      currency: 'USD',
      locale: 'en',
      date_format: '%m-%d-%Y'
    )
  end

  let(:role) { :admin }

  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123',
      role: role
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Key',
      key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Read Only Docs Key',
      key: key,
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/users/reset' do
    delete 'Reset account' do
      tags 'Users'
      description 'Resets all financial data (accounts, categories, merchants, tags, etc.) ' \
                  'for the current user\'s family while keeping the user account intact. ' \
                  'The reset runs asynchronously in the background. ' \
                  'The returned job_id is informational only; reset status is family-scoped, not job-scoped. ' \
                  'Requires admin role.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'account reset initiated' do
        schema '$ref' => '#/components/schemas/ResetInitiatedResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end

      response '403', 'forbidden - requires read_write scope and admin role' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'Read Only Key',
            key: key,
            scopes: %w[read],
            source: 'web'
          )
        end

        run_test!
      end

      response '500', 'reset enqueue failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow(FamilyResetJob).to receive(:perform_later).and_raise(StandardError, 'queue down')
        end

        run_test!
      end
    end
  end

  path '/api/v1/users/reset_with_sample_data' do
    delete 'Reset account and load sample data' do
      tags 'Users'
      description 'Resets all financial data for the current user\'s family and then loads demo sample data for the authenticated user. ' \
                  'The reset and sample-data generation run asynchronously in the background. ' \
                  'Requires admin role.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'account reset with sample data initiated' do
        schema '$ref' => '#/components/schemas/ResetInitiatedResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end

      response '403', 'forbidden - requires read_write scope and admin role' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'Read Only Key',
            key: key,
            scopes: %w[read],
            source: 'web'
          )
        end

        run_test!
      end

      response '500', 'reset enqueue failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow(FamilyResetJob).to receive(:perform_later).and_raise(StandardError, 'queue down')
        end

        run_test!
      end
    end
  end

  path '/api/v1/users/reset/status' do
    get 'Retrieve reset status' do
      tags 'Users'
      description 'Returns counts of family-owned data targeted by account reset. ' \
                  'Use this after DELETE /api/v1/users/reset to decide whether reset materialization has completed. ' \
                  'Completion is a counts-based family snapshot and may change if new data is created after reset.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'reset status returned' do
        schema '$ref' => '#/components/schemas/ResetStatusResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end

      response '403', 'forbidden - requires admin role' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:role) { :member }

        run_test!
      end
    end
  end

  path '/api/v1/users/me' do
    get 'Retrieve current user profile' do
      tags 'Users'
      description 'Returns the current user, family settings, and supported preference option keys for mobile settings screens.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'current user profile returned' do
        schema '$ref' => '#/components/schemas/UserProfileResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end
    end

    patch 'Update current user profile' do
      tags 'Users'
      description 'Updates current-user profile and preference fields. Admins may also update nested family settings.'
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
              last_name: { type: :string },
              email: { type: :string, format: :email },
              locale: { type: :string },
              theme: { type: :string, enum: %w[light dark system] },
              default_period: { type: :string },
              default_account_order: { type: :string },
              show_sidebar: { type: :boolean },
              show_ai_sidebar: { type: :boolean },
              ai_enabled: { type: :boolean },
              goals: { type: :array, items: { type: :string } },
              family: {
                type: :object,
                description: 'Admin-only family settings update payload.',
                properties: {
                  name: { type: :string },
                  currency: { type: :string },
                  country: { type: :string },
                  date_format: { type: :string },
                  timezone: { type: :string },
                  locale: { type: :string },
                  month_start_day: { type: :integer },
                  moniker: { type: :string },
                  default_account_sharing: { type: :string, enum: %w[shared private] },
                  enabled_currencies: { type: :array, items: { type: :string } }
                }
              }
            }
          }
        },
        required: %w[user]
      }

      let(:body) do
        {
          user: {
            first_name: 'Mobile',
            last_name: 'User',
            default_period: 'last_7_days',
            default_account_order: 'balance_desc',
            theme: 'dark'
          }
        }
      end

      response '200', 'current user profile updated' do
        schema '$ref' => '#/components/schemas/UserProfileResponse'

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '422', 'validation failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            user: {
              default_period: 'not-a-period'
            }
          }
        end

        run_test!
      end
    end

    delete 'Delete account' do
      tags 'Users'
      description 'Permanently deactivates the current user account and all associated data. ' \
                  'This action cannot be undone.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'account deleted' do
        schema '$ref' => '#/components/schemas/SuccessMessage'

        run_test!
      end

      response '401', 'unauthorized' do
        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end

      response '403', 'insufficient scope' do
        let(:api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'Read Only Key',
            key: key,
            scopes: %w[read],
            source: 'web'
          )
        end

        run_test!
      end

      response '422', 'deactivation failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          api_key
          allow_any_instance_of(User).to receive(:deactivate).and_return(false)
          allow_any_instance_of(User).to receive(:errors).and_return(
            double(full_messages: [ 'Cannot deactivate admin with other users' ])
          )
        end

        run_test!
      end
    end
  end

  path '/api/v1/users/me/rule_prompt_settings' do
    patch 'Update rule prompt settings' do
      tags 'Users'
      description 'Updates the current user rule-prompt dismissal/preferences used by transaction categorization suggestions.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              rule_prompts_disabled: { type: :boolean },
              rule_prompt_dismissed_at: { type: :string, format: :'date-time', nullable: true }
            }
          }
        },
        required: %w[user]
      }

      let(:body) do
        {
          user: {
            rule_prompts_disabled: true,
            rule_prompt_dismissed_at: Time.current.iso8601
          }
        }
      end

      response '200', 'rule prompt settings updated' do
        schema '$ref' => '#/components/schemas/UserProfileResponse'

        run_test!
      end
    end
  end

  path '/api/v1/users/me/password' do
    patch 'Update current user password' do
      tags 'Users'
      description 'Changes the current user password. Requires the current password in password_challenge.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          user: {
            type: :object,
            properties: {
              password: { type: :string, minLength: 8 },
              password_confirmation: { type: :string, minLength: 8 },
              password_challenge: { type: :string, description: 'Current password' }
            },
            required: %w[password password_confirmation password_challenge]
          }
        },
        required: %w[user]
      }

      let(:body) do
        {
          user: {
            password: 'new-mobile-password-123',
            password_confirmation: 'new-mobile-password-123',
            password_challenge: 'password123'
          }
        }
      end

      response '200', 'password updated' do
        schema '$ref' => '#/components/schemas/UserProfileResponse'

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '422', 'validation failed' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            user: {
              password: 'new-mobile-password-123',
              password_confirmation: 'new-mobile-password-123',
              password_challenge: 'wrong-password'
            }
          }
        end

        run_test!
      end
    end
  end
end
