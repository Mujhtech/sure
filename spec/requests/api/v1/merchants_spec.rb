# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Merchants', type: :request do
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

  let(:'X-Api-Key') { api_key.plain_key }

  let!(:family_merchant) { family.merchants.create!(name: 'Coffee Shop') }

  describe 'JSON merchant writes' do
    let(:headers) { { 'X-Api-Key' => api_key.plain_key } }

    it 'preserves the supplied color when creating a merchant' do
      post '/api/v1/merchants',
           params: {
             merchant: {
               name: 'Blue Bottle',
               color: '#6471eb',
               website_url: 'https://bluebottlecoffee.com'
             }
           },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['color']).to eq('#6471eb')
      expect(family.merchants.find_by!(name: 'Blue Bottle').color).to eq('#6471eb')
    end

    it 'preserves the supplied color when updating a merchant' do
      patch "/api/v1/merchants/#{family_merchant.id}",
            params: {
              merchant: {
                name: family_merchant.name,
                color: '#61c9ea'
              }
            },
            headers: headers,
            as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['color']).to eq('#61c9ea')
      expect(family_merchant.reload.color).to eq('#61c9ea')
    end
  end

  path '/api/v1/merchants' do
    get 'List merchants' do
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'merchants listed' do
        schema type: :array, items: { '$ref' => '#/components/schemas/MerchantDetail' }

        run_test!
      end
    end

    post 'Import merchants from CSV' do
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      consumes 'multipart/form-data'
      produces 'application/json'

      parameter name: :file, in: :formData, type: :file, required: true,
                description: 'CSV file with columns: name* (required), color, website_url'

      response '201', 'merchants imported' do
        schema '$ref' => '#/components/schemas/MerchantImportResult'

        let(:file) do
          Rack::Test::UploadedFile.new(
            StringIO.new("name,color,website_url\nCoffee Shop,#e99537,https://coffeeshop.com"),
            'text/csv',
            true,
            original_filename: 'merchants.csv'
          )
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        run_test!
      end

      response '422', 'missing file or invalid CSV' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:file) { nil }
        run_test!
      end
    end
  end

  path '/api/v1/merchants/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Merchant ID'

    get 'Retrieve a merchant' do
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'merchant retrieved' do
        schema '$ref' => '#/components/schemas/MerchantDetail'

        let(:id) { family_merchant.id }

        run_test!
      end

      response '404', 'merchant not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/merchants/merge' do
    post 'Merge merchants' do
      description 'Move family transactions from source merchants to a target merchant, then delete source family merchants while preserving provider merchants.'
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        '$ref' => '#/components/schemas/MerchantMergeRequest'
      }

      let!(:source_merchant) { family.merchants.create!(name: 'Old Coffee Shop') }

      response '200', 'merchants merged' do
        schema '$ref' => '#/components/schemas/MerchantMergeResponse'

        let(:body) { { target_id: family_merchant.id, source_ids: [ source_merchant.id ] } }

        run_test!
      end

      response '422', 'invalid merge request' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { target_id: family_merchant.id, source_ids: [ family_merchant.id ] } }

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:read_only_api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'API Docs Read Key',
            key: key,
            scopes: %w[read],
            source: 'mobile'
          )
        end
        let(:'X-Api-Key') { read_only_api_key.plain_key }
        let(:body) { { target_id: family_merchant.id, source_ids: [ source_merchant.id ] } }

        run_test!
      end
    end
  end

  path '/api/v1/merchants/enhance' do
    post 'Start provider merchant enhancement' do
      description 'Queue a background job to enrich assigned provider merchants that are missing website metadata.'
      tags 'Merchants'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '202', 'merchant enhancement started' do
        schema '$ref' => '#/components/schemas/MerchantEnhanceResponse'

        before do
          Rails.cache.delete("enhance_provider_merchants:#{family.id}")
        end

        run_test!
      end

      response '422', 'merchant enhancement already running' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          Rails.cache.write("enhance_provider_merchants:#{family.id}", true, expires_in: 10.minutes)
        end

        after do
          Rails.cache.delete("enhance_provider_merchants:#{family.id}")
        end

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:read_only_api_key) do
          key = ApiKey.generate_secure_key
          ApiKey.create!(
            user: user,
            name: 'API Docs Read Key',
            key: key,
            scopes: %w[read],
            source: 'mobile'
          )
        end
        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end
    end
  end
end
