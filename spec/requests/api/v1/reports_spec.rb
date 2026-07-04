# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Reports', type: :request do
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
      scopes: %w[read],
      source: 'mobile'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:account) do
    Account.create!(
      family: family,
      name: 'Checking Account',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.create!
    )
  end

  let(:category) do
    family.categories.create!(
      name: 'Groceries',
      color: '#4CAF50',
      lucide_icon: 'shopping-cart'
    )
  end

  let!(:expense_transaction) do
    account.entries.create!(
      name: 'Groceries',
      date: Date.current,
      amount: 42.25,
      currency: 'USD',
      entryable: Transaction.new(category: category)
    )
  end

  let!(:income_transaction) do
    account.entries.create!(
      name: 'Paycheck',
      date: Date.current,
      amount: -1500.00,
      currency: 'USD',
      entryable: Transaction.new
    )
  end

  path '/api/v1/reports' do
    get 'Show report dashboard' do
      tags 'Reports'
      description 'Returns the mobile dashboard report payload: period metadata, income and expense summary, trends, net worth, transaction category breakdown, and investment metrics.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :period_type, in: :query, required: false,
                schema: { type: :string, enum: %w[monthly quarterly ytd last_6_months custom] },
                description: 'Report period preset. Defaults to monthly.'
      parameter name: :start_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Custom report start date. ISO 8601 only.'
      parameter name: :end_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Custom report end date. ISO 8601 only.'
      parameter name: :sort_by, in: :query, required: false,
                schema: { type: :string, enum: %w[amount count] },
                description: 'Sort transaction breakdown rows by amount or count.'
      parameter name: :sort_direction, in: :query, required: false,
                schema: { type: :string, enum: %w[asc desc] },
                description: 'Sort direction for transaction breakdown rows.'
      parameter name: :filter_account_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Restrict report transactions to one finance account.'
      parameter name: :filter_category_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Restrict transaction breakdown to a category and its subcategories.'
      parameter name: :filter_tag_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Restrict transaction breakdown to transactions with this tag.'
      parameter name: :filter_amount_min, in: :query, required: false,
                schema: { type: :number },
                description: 'Minimum absolute transaction amount.'
      parameter name: :filter_amount_max, in: :query, required: false,
                schema: { type: :number },
                description: 'Maximum absolute transaction amount.'
      parameter name: :filter_date_start, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Additional lower date bound within the selected period.'
      parameter name: :filter_date_end, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Additional upper date bound within the selected period.'

      let(:period_type) { 'custom' }
      let(:start_date) { Date.current.beginning_of_month.to_s }
      let(:end_date) { Date.current.end_of_month.to_s }

      response '200', 'report returned' do
        schema '$ref' => '#/components/schemas/ReportResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '422', 'invalid date filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:start_date) { '06/01/2026' }

        run_test!
      end

      response '422', 'invalid account filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:filter_account_id) { 'not-a-uuid' }

        run_test!
      end
    end
  end

  path '/api/v1/reports/export_transactions' do
    get 'Export transaction breakdown CSV' do
      tags 'Reports'
      description 'Exports the filtered monthly transaction category breakdown as CSV for sharing or spreadsheet import.'
      security [ { apiKeyAuth: [] } ]
      produces 'text/csv', 'application/json'
      parameter name: :period_type, in: :query, required: false,
                schema: { type: :string, enum: %w[monthly quarterly ytd last_6_months custom] },
                description: 'Report period preset. Defaults to monthly.'
      parameter name: :start_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Custom report start date. ISO 8601 only.'
      parameter name: :end_date, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Custom report end date. ISO 8601 only.'
      parameter name: :filter_account_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Restrict report transactions to one finance account.'
      parameter name: :filter_category_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Restrict transaction breakdown to a category and its subcategories.'
      parameter name: :filter_tag_id, in: :query, required: false,
                schema: { type: :string, format: :uuid },
                description: 'Restrict transaction breakdown to transactions with this tag.'
      parameter name: :filter_amount_min, in: :query, required: false,
                schema: { type: :number },
                description: 'Minimum absolute transaction amount.'
      parameter name: :filter_amount_max, in: :query, required: false,
                schema: { type: :number },
                description: 'Maximum absolute transaction amount.'
      parameter name: :filter_date_start, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Additional lower date bound within the selected period.'
      parameter name: :filter_date_end, in: :query, required: false,
                schema: { type: :string, format: :date },
                description: 'Additional upper date bound within the selected period.'

      let(:period_type) { 'custom' }
      let(:start_date) { Date.current.beginning_of_month.to_s }
      let(:end_date) { Date.current.end_of_month.to_s }

      response '200', 'csv exported' do
        schema type: :string

        run_test!
      end

      response '422', 'invalid date filter' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:start_date) { '06/01/2026' }

        run_test!
      end
    end
  end
end
