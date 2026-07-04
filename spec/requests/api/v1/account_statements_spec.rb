# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Account Statements', type: :request do
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
  let!(:statement) do
    AccountStatement.create_from_upload!(
      family: family,
      account: account,
      file: Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/imports/valid.csv'), 'text/csv')
    )
  end

  path '/api/v1/account_statements' do
    get 'List account statements' do
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :account_id, in: :query, type: :string, required: false
      parameter name: :review_status, in: :query, type: :string, required: false,
                enum: %w[unmatched linked rejected]
      parameter name: :upload_status, in: :query, type: :string, required: false,
                enum: %w[stored failed]

      response '200', 'account statements listed' do
        schema '$ref' => '#/components/schemas/AccountStatementCollection'

        run_test!
      end
    end

    post 'Upload account statement' do
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]
      consumes 'multipart/form-data'
      produces 'application/json'
      parameter name: :file, in: :formData, type: :file, required: true,
                description: 'PDF, CSV, or XLSX statement file'
      parameter name: :account_id, in: :formData, type: :string, required: false

      let(:file) { Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/imports/actual.csv'), 'text/csv') }
      let(:account_id) { account.id }

      response '201', 'account statement uploaded' do
        schema '$ref' => '#/components/schemas/AccountStatementUploadResponse'

        run_test!
      end
    end
  end

  path '/api/v1/account_statements/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Account statement ID'

    get 'Retrieve account statement' do
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { statement.id }

      response '200', 'account statement retrieved' do
        schema '$ref' => '#/components/schemas/AccountStatement'

        run_test!
      end
    end

    patch 'Update account statement' do
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          account_statement: {
            type: :object,
            properties: {
              account_id: { type: :string, format: :uuid, nullable: true },
              institution_name_hint: { type: :string, nullable: true },
              account_name_hint: { type: :string, nullable: true },
              account_last4_hint: { type: :string, nullable: true },
              period_start_on: { type: :string, format: :date, nullable: true },
              period_end_on: { type: :string, format: :date, nullable: true },
              opening_balance: { type: :string, nullable: true },
              closing_balance: { type: :string, nullable: true },
              currency: { type: :string, nullable: true }
            }
          }
        }
      }

      let(:id) { statement.id }
      let(:body) { { account_statement: { institution_name_hint: 'Mobile Bank' } } }

      response '200', 'account statement updated' do
        schema '$ref' => '#/components/schemas/AccountStatement'

        run_test!
      end
    end

    delete 'Delete account statement' do
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { statement.id }

      response '200', 'account statement deleted' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end
    end
  end

  path '/api/v1/account_statements/{id}/link' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Account statement ID'

    patch 'Link account statement to an account' do
      tags 'Account Statements'
      description 'Links an unmatched statement to the supplied account_id, or to the statement suggested_account when account_id is omitted.'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          account_id: { type: :string, format: :uuid, nullable: true }
        }
      }

      let(:id) { statement.id }
      let(:body) { { account_id: account.id } }

      response '200', 'account statement linked' do
        schema '$ref' => '#/components/schemas/AccountStatement'

        run_test!
      end

      response '404', 'account or statement not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { account_id: SecureRandom.uuid } }

        run_test!
      end
    end
  end

  path '/api/v1/account_statements/{id}/unlink' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Account statement ID'

    patch 'Unlink account statement from its account' do
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { statement.id }

      response '200', 'account statement unlinked' do
        schema '$ref' => '#/components/schemas/AccountStatement'

        run_test!
      end
    end
  end

  path '/api/v1/account_statements/{id}/reject' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Account statement ID'

    patch 'Reject suggested account statement match' do
      tags 'Account Statements'
      description 'Marks an unmatched statement suggestion as rejected and clears suggested_account.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { statement.id }

      before do
        statement.update!(account: nil, suggested_account: account, match_confidence: 0.9)
      end

      response '200', 'account statement suggestion rejected' do
        schema '$ref' => '#/components/schemas/AccountStatement'

        run_test!
      end
    end
  end

  path '/api/v1/account_statements/{id}/download' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Account statement ID'

    get 'Download account statement file' do
      tags 'Account Statements'
      security [ { apiKeyAuth: [] } ]

      let(:id) { statement.id }

      response '302', 'redirects to statement file' do
        run_test!
      end
    end
  end
end
