# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Transaction Splits', type: :request do
  let(:family) { Family.create!(name: 'API Family', currency: 'USD', locale: 'en') }
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
    ApiKey.create!(user: user, name: 'API Docs Key', key: key, scopes: %w[read_write], source: 'mobile')
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Checking',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.create!
    )
  end
  let!(:transaction) do
    entry = account.entries.create!(
      name: 'Grocery Store',
      date: Date.current,
      amount: 100,
      currency: 'USD',
      entryable: Transaction.new
    )
    entry.entryable
  end

  path '/api/v1/transactions/{transaction_id}/split' do
    parameter name: :transaction_id, in: :path, type: :string, required: true, description: 'Transaction ID'

    get 'Retrieve transaction split details' do
      tags 'Transaction Splits'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:transaction_id) { transaction.id }

      response '200', 'split details returned' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end
    end

    post 'Split a transaction' do
      tags 'Transaction Splits'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[split],
        properties: {
          split: {
            type: :object,
            required: %w[splits],
            properties: {
              splits: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionSplitInput' }
              }
            }
          }
        }
      }

      let(:transaction_id) { transaction.id }
      let(:body) do
        {
          split: {
            splits: [
              { name: 'Groceries', amount: '-70' },
              { name: 'Household', amount: '-30' }
            ]
          }
        }
      end

      response '201', 'transaction split created' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end
    end

    patch 'Update transaction split lines' do
      tags 'Transaction Splits'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[split],
        properties: {
          split: {
            type: :object,
            required: %w[splits],
            properties: {
              splits: {
                type: :array,
                items: { '$ref' => '#/components/schemas/TransactionSplitInput' }
              }
            }
          }
        }
      }

      before do
        transaction.entry.split!([
          { name: 'Part 1', amount: 60, category_id: nil },
          { name: 'Part 2', amount: 40, category_id: nil }
        ])
      end

      let(:transaction_id) { transaction.id }
      let(:body) do
        {
          split: {
            splits: [
              { name: 'Food', amount: '-50' },
              { name: 'Transport', amount: '-30' },
              { name: 'Other', amount: '-20' }
            ]
          }
        }
      end

      response '200', 'transaction split updated' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end
    end

    delete 'Remove transaction split' do
      tags 'Transaction Splits'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      before do
        transaction.entry.split!([
          { name: 'Part 1', amount: 60, category_id: nil },
          { name: 'Part 2', amount: 40, category_id: nil }
        ])
      end

      let(:transaction_id) { transaction.id }

      response '200', 'transaction unsplit' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end
    end
  end
end
