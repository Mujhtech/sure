# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Rules', type: :request do
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
      source: 'web'
    )
  end

  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to document the runtime insufficient-scope response.
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: [],
      display_key: key,
      source: 'mobile'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:rule) do
    family.rules.build(
      name: 'Coffee cleanup',
      resource_type: 'transaction',
      active: true,
      effective_date: Date.new(2024, 1, 1)
    ).tap do |rule|
      rule.conditions.build(condition_type: 'transaction_name', operator: 'like', value: 'coffee')
      rule.actions.build(action_type: 'set_transaction_name', value: 'Coffee')
      rule.save!
    end
  end

  path '/api/v1/rules' do
    get 'List rules' do
      tags 'Rules'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :resource_type, in: :query, required: false,
                description: 'Filter by rule resource type',
                schema: { type: :string, enum: %w[transaction] }
      parameter name: :active, in: :query, required: false,
                description: 'Filter by active status',
                schema: { type: :boolean }

      response '200', 'rules listed' do
        schema '$ref' => '#/components/schemas/RuleCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'forbidden - requires read scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'invalid active filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:active) { 'not_boolean' }

        run_test!
      end

      response '422', 'unsupported resource type' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:resource_type) { 'account' }

        run_test!
      end
    end

    post 'Create a rule' do
      tags 'Rules'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[rule],
        properties: {
          rule: {
            type: :object,
            required: %w[resource_type actions_attributes],
            properties: {
              name: { type: :string, nullable: true },
              resource_type: { type: :string, enum: %w[transaction] },
              active: { type: :boolean },
              effective_date: { type: :string, format: :date, nullable: true },
              conditions_attributes: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleConditionInput' }
              },
              actions_attributes: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleActionInput' }
              }
            }
          }
        }
      }

      let(:body) do
        {
          rule: {
            name: 'Mobile coffee cleanup',
            resource_type: 'transaction',
            active: true,
            conditions_attributes: [
              { condition_type: 'transaction_name', operator: 'like', value: 'coffee' }
            ],
            actions_attributes: [
              { action_type: 'set_transaction_name', value: 'Coffee' }
            ]
          }
        }
      end

      response '201', 'rule created' do
        schema '$ref' => '#/components/schemas/RuleResponse'

        run_test!
      end

      response '422', 'unsupported resource type' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            rule: {
              name: 'Bad rule',
              resource_type: 'account',
              actions_attributes: [
                { action_type: 'set_transaction_name', value: 'Coffee' }
              ]
            }
          }
        end

        run_test!
      end
    end

  end

  path '/api/v1/rules/apply_all' do
    post 'Apply all rules' do
      tags 'Rules'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '202', 'apply all queued' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end
    end
  end

  path '/api/v1/rules/destroy_all' do
    delete 'Delete all rules' do
      tags 'Rules'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'rules deleted' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end
    end
  end

  path '/api/v1/rules/clear_ai_cache' do
    post 'Clear AI cache' do
      tags 'Rules'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '202', 'cache clear queued' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end
    end
  end

  path '/api/v1/rules/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Rule ID'

    get 'Retrieve a rule' do
      tags 'Rules'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { rule.id }

      response '200', 'rule retrieved' do
        schema '$ref' => '#/components/schemas/RuleResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'forbidden - requires read scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'rule not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a rule' do
      tags 'Rules'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[rule],
        properties: {
          rule: {
            type: :object,
            properties: {
              name: { type: :string, nullable: true },
              active: { type: :boolean },
              effective_date: { type: :string, format: :date, nullable: true },
              conditions_attributes: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleConditionInput' }
              },
              actions_attributes: {
                type: :array,
                items: { '$ref' => '#/components/schemas/RuleActionInput' }
              }
            }
          }
        }
      }

      let(:id) { rule.id }
      let(:body) { { rule: { name: 'Updated coffee cleanup', active: false } } }

      response '200', 'rule updated' do
        schema '$ref' => '#/components/schemas/RuleResponse'

        run_test!
      end
    end

    delete 'Delete a rule' do
      tags 'Rules'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { rule.id }

      response '200', 'rule deleted' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end
    end
  end

  path '/api/v1/rules/{id}/apply' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Rule ID'

    post 'Apply a rule' do
      tags 'Rules'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { rule.id }

      response '202', 'rule apply queued' do
        schema '$ref' => '#/components/schemas/RuleResponse'

        run_test!
      end
    end
  end
end
