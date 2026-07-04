# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Goal Pledges', type: :request do
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
      email: 'api-goal-pledges@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:account) do
    family.accounts.create!(
      owner: user,
      name: 'Savings',
      accountable: Depository.new,
      balance: 2500,
      currency: 'USD'
    )
  end

  let(:goal) do
    family.goals.create!(
      name: 'Emergency Fund',
      target_amount: 10_000,
      currency: 'USD',
      color: '#4da568',
      goal_accounts: [ GoalAccount.new(account: account) ]
    )
  end

  let(:pledge) do
    goal.goal_pledges.create!(
      account: account,
      amount: 100,
      currency: 'USD',
      kind: 'transfer'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Goal Pledges Write Key',
      key: key,
      display_key: key,
      scopes: %w[read_write],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  pledge_schema = {
    type: :object,
    required: %w[id goal_id amount_cents currency kind status account],
    properties: {
      id: { type: :string, format: :uuid },
      goal_id: { type: :string, format: :uuid },
      amount: { type: :string },
      amount_cents: { type: :integer },
      currency: { type: :string },
      kind: { type: :string, enum: %w[transfer manual_save] },
      status: { type: :string, enum: %w[open matched cancelled expired] },
      expires_at: { type: :string, format: :'date-time' },
      days_left: { type: :integer },
      matched_transaction_id: { type: :string, format: :uuid, nullable: true },
      account: { type: :object }
    }
  }

  path '/api/v1/goals/{goal_id}/pledges' do
    parameter name: :goal_id, in: :path, required: true,
              schema: { type: :string, format: :uuid }

    post 'Create goal pledge' do
      tags 'Goal Pledges'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[goal_pledge],
        properties: {
          goal_pledge: {
            type: :object,
            required: %w[account_id amount],
            properties: {
              account_id: { type: :string, format: :uuid },
              amount: { type: :number }
            }
          }
        }
      }

      let(:goal_id) { goal.id }
      let(:body) { { goal_pledge: { account_id: account.id, amount: 250 } } }

      response '201', 'pledge created' do
        schema pledge_schema

        run_test!
      end
    end
  end

  path '/api/v1/goals/{goal_id}/pledges/{id}/renew' do
    parameter name: :goal_id, in: :path, required: true,
              schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true,
              schema: { type: :string, format: :uuid }

    patch 'Renew goal pledge' do
      tags 'Goal Pledges'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:goal_id) { goal.id }
      let(:id) { pledge.id }

      response '200', 'pledge renewed' do
        schema pledge_schema

        run_test!
      end
    end
  end

  path '/api/v1/goals/{goal_id}/pledges/{id}' do
    parameter name: :goal_id, in: :path, required: true,
              schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true,
              schema: { type: :string, format: :uuid }

    delete 'Cancel goal pledge' do
      tags 'Goal Pledges'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:goal_id) { goal.id }
      let(:id) { pledge.id }

      response '200', 'pledge cancelled' do
        schema pledge_schema

        run_test!
      end
    end
  end
end
