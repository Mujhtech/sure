# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Transaction Attachments', type: :request do
  let(:family) { Family.create!(name: 'API Family', currency: 'USD', locale: 'en') }
  let(:user) do
    family.users.create!(
      email: 'api-user@example.com',
      password: 'password123',
      password_confirmation: 'password123'
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
      name: 'Coffee',
      date: Date.current,
      amount: 12.34,
      currency: 'USD',
      entryable: Transaction.new
    )
    entry.entryable
  end

  path '/api/v1/transactions/{transaction_id}/attachments' do
    parameter name: :transaction_id, in: :path, type: :string, required: true, description: 'Transaction ID'

    get 'List transaction attachments' do
      tags 'Transaction Attachments'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:transaction_id) { transaction.id }

      response '200', 'attachments listed' do
        schema '$ref' => '#/components/schemas/TransactionAttachmentCollection'

        run_test!
      end
    end

    post 'Upload transaction attachment' do
      tags 'Transaction Attachments'
      security [ { apiKeyAuth: [] } ]
      consumes 'multipart/form-data'
      produces 'application/json'
      parameter name: :attachment, in: :formData, type: :file, required: true,
                description: 'Receipt/invoice image or PDF'

      let(:transaction_id) { transaction.id }
      let(:attachment) { Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/test.txt'), 'application/pdf') }

      response '201', 'attachment uploaded' do
        schema '$ref' => '#/components/schemas/TransactionAttachmentCollection'

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{transaction_id}/attachments/{id}' do
    parameter name: :transaction_id, in: :path, type: :string, required: true, description: 'Transaction ID'
    parameter name: :id, in: :path, type: :string, required: true, description: 'Attachment ID'

    delete 'Delete transaction attachment' do
      tags 'Transaction Attachments'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:transaction_id) { transaction.id }
      let(:id) do
        transaction.attachments.attach(io: StringIO.new('%PDF-1.4'), filename: 'receipt.pdf', content_type: 'application/pdf')
        transaction.attachments.last.id
      end

      response '200', 'attachment deleted' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end
    end
  end
end
