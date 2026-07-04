# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Family Documents', type: :request do
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
  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: 'API Docs Read Key', key: key, scopes: %w[read], source: 'mobile')
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let!(:family_document) do
    family.family_documents.create!(
      filename: 'tax_notes.txt',
      content_type: 'text/plain',
      file_size: 120,
      provider_file_id: 'file-tax-notes',
      status: 'ready',
      metadata: { 'source' => 'spec' }
    )
  end
  let(:adapter) do
    double(
      'vector_store_adapter',
      supported_extensions: %w[.txt .csv .pdf],
      create_store: VectorStore::Response.new(success?: true, data: { id: 'vs-api-docs' }, error: nil),
      upload_file: VectorStore::Response.new(success?: true, data: { file_id: 'file-uploaded' }, error: nil),
      search: VectorStore::Response.new(
        success?: true,
        data: [ { filename: 'tax_notes.txt', content: 'Total income was 120000', score: 0.91 } ],
        error: nil
      ),
      remove_file: VectorStore::Response.new(success?: true, data: {}, error: nil)
    )
  end

  before do
    allow(VectorStore).to receive(:adapter).and_return(adapter)
  end

  path '/api/v1/family_documents' do
    get 'List family documents' do
      description 'List documents uploaded to the family document store and return vector-store upload capabilities.'
      tags 'Family Documents'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :per_page, in: :query, type: :integer, required: false

      response '200', 'family documents listed' do
        schema '$ref' => '#/components/schemas/FamilyDocumentCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end
    end

    post 'Upload family document' do
      description 'Upload a non-PDF document to the family vector store so AI chat can search it. PDFs should be uploaded through POST /api/v1/imports.'
      tags 'Family Documents'
      security [ { apiKeyAuth: [] } ]
      consumes 'multipart/form-data'
      produces 'application/json'
      parameter name: :file, in: :formData, type: :file, required: true,
                description: 'Non-PDF document accepted by the configured vector-store provider.'

      let(:file) { Rack::Test::UploadedFile.new(StringIO.new('hello docs'), 'text/plain', original_filename: 'notes.txt') }

      response '201', 'family document uploaded' do
        schema '$ref' => '#/components/schemas/FamilyDocumentResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '503', 'vector store provider not configured' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow(VectorStore).to receive(:adapter).and_return(nil)
        end

        run_test!
      end
    end
  end

  path '/api/v1/family_documents/search' do
    get 'Search family documents' do
      description 'Search uploaded family documents and return relevant excerpts with source filenames.'
      tags 'Family Documents'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :query, in: :query, type: :string, required: true
      parameter name: :max_results, in: :query, type: :integer, required: false,
                description: 'Maximum results to return (default 10, max 20).'

      let(:query) { 'tax total' }
      let(:max_results) { 3 }

      before do
        family.update!(vector_store_id: 'vs-api-docs')
      end

      response '200', 'family documents searched' do
        schema '$ref' => '#/components/schemas/FamilyDocumentSearchResponse'

        run_test!
      end

      response '422', 'query missing' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:query) { nil }

        run_test!
      end
    end
  end

  path '/api/v1/family_documents/{id}' do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    get 'Retrieve family document' do
      tags 'Family Documents'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { family_document.id }

      response '200', 'family document retrieved' do
        schema '$ref' => '#/components/schemas/FamilyDocumentResponse'

        run_test!
      end

      response '404', 'family document not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    delete 'Delete family document' do
      tags 'Family Documents'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { family_document.id }

      before do
        family.update!(vector_store_id: 'vs-api-docs')
      end

      response '200', 'family document deleted' do
        schema '$ref' => '#/components/schemas/DeleteResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response '404', 'family document not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
