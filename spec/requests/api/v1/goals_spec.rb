# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Goals', type: :request do
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
      email: 'api-goals@example.com',
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

  let(:read_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Goals Read Key',
      key: key,
      display_key: key,
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:write_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'Goals Write Key',
      key: key,
      display_key: key,
      scopes: %w[read_write],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { read_key.plain_key }

  goal_schema = {
    type: :object,
    required: %w[id name currency target_amount_cents state status linked_accounts open_pledges],
    properties: {
      id: { type: :string, format: :uuid },
      name: { type: :string },
      currency: { type: :string },
      state: { type: :string, enum: %w[active paused completed archived] },
      status: { type: :string },
      target_amount_cents: { type: :integer },
      current_balance_cents: { type: :integer },
      remaining_amount_cents: { type: :integer },
      progress_percent: { type: :integer },
      linked_accounts: { type: :array, items: { type: :object } },
      open_pledges: { type: :array, items: { type: :object } },
      created_at: { type: :string, format: :'date-time' },
      updated_at: { type: :string, format: :'date-time' }
    }
  }

  path '/api/v1/goals' do
    get 'List goals' do
      tags 'Goals'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :per_page, in: :query, type: :integer, required: false
      parameter name: :state, in: :query, required: false,
                schema: { type: :string, enum: %w[active paused completed archived] }
      parameter name: :search, in: :query, type: :string, required: false

      response '200', 'goals listed' do
        schema type: :object,
               required: %w[goals pagination],
               properties: {
                 goals: { type: :array, items: goal_schema },
                 pagination: { '$ref' => '#/components/schemas/Pagination' }
               }

        before { goal }

        run_test!
      end
    end

    post 'Create goal' do
      tags 'Goals'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[goal],
        properties: {
          goal: {
            type: :object,
            required: %w[name target_amount account_ids],
            properties: {
              name: { type: :string },
              target_amount: { type: :number },
              target_date: { type: :string, format: :date, nullable: true },
              color: { type: :string, nullable: true },
              icon: { type: :string, nullable: true },
              notes: { type: :string, nullable: true },
              account_ids: { type: :array, items: { type: :string, format: :uuid } },
              allocations: { type: :object, additionalProperties: { type: :string } }
            }
          }
        }
      }

      let(:'X-Api-Key') { write_key.plain_key }
      let(:body) do
        {
          goal: {
            name: 'Mobile Goal',
            target_amount: 5000,
            account_ids: [ account.id ],
            allocations: { account.id => '1000' }
          }
        }
      end

      response '201', 'goal created' do
        schema goal_schema

        run_test!
      end
    end
  end

  path '/api/v1/goals/{id}' do
    parameter name: :id, in: :path, required: true,
              schema: { type: :string, format: :uuid }

    get 'Retrieve a goal' do
      tags 'Goals'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { goal.id }

      response '200', 'goal retrieved' do
        schema goal_schema

        run_test!
      end
    end

    patch 'Update a goal' do
      tags 'Goals'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          goal: { type: :object, additionalProperties: true }
        }
      }

      let(:'X-Api-Key') { write_key.plain_key }
      let(:id) { goal.id }
      let(:body) { { goal: { name: 'Updated Goal' } } }

      response '200', 'goal updated' do
        schema goal_schema

        run_test!
      end
    end

    delete 'Delete an archived goal' do
      tags 'Goals'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:'X-Api-Key') { write_key.plain_key }
      let(:id) do
        goal.update!(state: 'archived')
        goal.id
      end

      response '200', 'goal deleted' do
        schema type: :object, properties: { message: { type: :string } }

        run_test!
      end
    end
  end

  %w[pause resume complete archive unarchive reopen].each do |event|
    path "/api/v1/goals/{id}/#{event}" do
      parameter name: :id, in: :path, required: true,
                schema: { type: :string, format: :uuid }

      patch "#{event.humanize} a goal" do
        tags 'Goals'
        security [ { apiKeyAuth: [] } ]
        produces 'application/json'

        let(:'X-Api-Key') { write_key.plain_key }
        let(:id) { goal.id }

        response '200', "goal #{event} transition applied" do
          schema goal_schema

          before do
            goal.pause! if event == 'resume'
            goal.archive! if event == 'unarchive'
            goal.complete! if event == 'reopen'
          end

          run_test!
        end
      end
    end
  end
end
