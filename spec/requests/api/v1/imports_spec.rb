# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Imports', type: :request do
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
    ApiKey.new(
      user: user,
      name: 'No Read Docs Key',
      key: key,
      scopes: %w[write],
      source: 'web'
    ).tap { |api_key| api_key.save!(validate: false) }
  end

  let(:'X-Api-Key') { api_key.plain_key }

  let(:account) do
    Account.create!(
      family: family,
      name: 'Test Checking',
      balance: 1000,
      currency: 'USD',
      accountable: Depository.new
    )
  end

  let!(:pending_import) do
    family.imports.create!(
      type: 'TransactionImport',
      status: 'pending',
      account: account,
      raw_file_str: "date,amount,name\n01/01/2024,10.00,Test Transaction"
    )
  end

  let(:qif_content) do
    <<~QIF
      !Type:Bank
      D1/ 2'24
      T-12.50
      PCoffee Shop
      LCafes/Mobile
      ^
      D1/ 3'24
      T-20.00
      PGrocery Store
      LGroceries/Weekly
      ^
    QIF
  end

  let(:qif_import) do
    family.imports.create!(
      type: 'QifImport',
      account: account,
      raw_file_str: qif_content
    ).tap do |import|
      import.generate_rows_from_csv
      import.sync_mappings
      import.reload
    end
  end

  let!(:import_row) do
    pending_import.rows.create!(
      source_row_number: 1,
      date: '01/01/2024',
      amount: '10.00',
      currency: 'USD',
      name: 'Test Transaction'
    )
  end

  let!(:mapped_category) do
    family.categories.create!(
      name: 'Mapped Category',
      color: '#407706',
      lucide_icon: 'shopping-basket'
    )
  end

  let!(:category_mapping) do
    Import::CategoryMapping.create!(
      import: pending_import,
      key: 'Test Category',
      mappable: mapped_category
    )
  end

  let!(:complete_import) do
    family.imports.create!(
      type: 'TransactionImport',
      status: 'complete',
      account: account,
      raw_file_str: "date,amount,name\n01/02/2024,20.00,Another Transaction"
    )
  end

  path '/api/v1/imports' do
    get 'List imports' do
      description 'List all imports for the user\'s family with pagination and filtering.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :status, in: :query, required: false,
                description: 'Filter by status',
                schema: { type: :string, enum: %w[pending complete importing reverting revert_failed failed] }
      parameter name: :type, in: :query, required: false,
                description: 'Filter by import type',
                schema: { type: :string, enum: Import::TYPES }

      response '200', 'imports listed' do
        schema '$ref' => '#/components/schemas/ImportCollection'

        run_test!
      end

      response '200', 'imports filtered by status' do
        schema '$ref' => '#/components/schemas/ImportCollection'

        let(:status) { 'pending' }

        run_test!
      end

      response '200', 'imports filtered by type' do
        schema '$ref' => '#/components/schemas/ImportCollection'

        let(:type) { 'TransactionImport' }

        run_test!
      end
    end

    post 'Create import' do
      description 'Create a new import from raw CSV content, raw or uploaded QIF content, inline or uploaded Sure NDJSON content, or an uploaded PDF bank/document statement. CSV and QIF content are limited to 10MB; PDF content is limited to 25MB. Uploaded PDFs create a PdfImport and queue AI processing.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json', 'multipart/form-data'
      produces 'application/json'

      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          raw_file_content: {
            type: :string,
            description: 'Raw CSV, QIF, or Sure NDJSON content as a string. CSV and QIF content are limited to 10MB. Required for QifImport and SureImport unless a multipart file is uploaded.'
          },
          file: {
            type: :string,
            format: :binary,
            description: 'Multipart CSV, QIF, Sure NDJSON, or PDF upload. PDF uploads create a PdfImport; type may be omitted when content_type is application/pdf.'
          },
          type: {
            type: :string,
            enum: Import::TYPES,
            description: 'Import type (defaults to TransactionImport)'
          },
          account_id: {
            type: :string,
            format: :uuid,
            description: 'Account ID to import into. Required for QifImport and optional for PdfImport.'
          },
          publish: {
            type: :string,
            description: 'Set to "true" to automatically queue for processing if configuration is valid'
          },
          date_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the date column'
          },
          amount_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the amount column'
          },
          name_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the transaction name column'
          },
          category_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the category column'
          },
          tags_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the tags column'
          },
          notes_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the notes column'
          },
          account_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the account column when importing rows across multiple accounts'
          },
          qty_col_label: {
            type: :string,
            description: 'CSV trade imports only. Header name for the quantity column'
          },
          ticker_col_label: {
            type: :string,
            description: 'CSV trade imports only. Header name for the ticker column'
          },
          price_col_label: {
            type: :string,
            description: 'CSV trade imports only. Header name for the price column'
          },
          entity_type_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the entity type column'
          },
          currency_col_label: {
            type: :string,
            description: 'CSV imports only. Header name for the currency column'
          },
          exchange_operating_mic_col_label: {
            type: :string,
            description: 'CSV trade imports only. Header name for the exchange operating MIC column'
          },
          date_format: {
            type: :string,
            description: 'CSV imports only. Date format pattern (e.g., "%m/%d/%Y")'
          },
          number_format: {
            type: :string,
            enum: [ '1,234.56', '1.234,56', '1 234,56', '1,234' ],
            description: 'CSV imports only. Number format for parsing amounts'
          },
          signage_convention: {
            type: :string,
            enum: %w[inflows_positive inflows_negative],
            description: 'CSV imports only. How to interpret positive/negative amounts'
          },
          col_sep: {
            type: :string,
            enum: [ ',', ';' ],
            description: 'CSV imports only. Column separator'
          },
          amount_type_strategy: {
            type: :string,
            enum: %w[signed_amount custom_column],
            description: 'CSV imports only. Amount parsing strategy'
          },
          amount_type_inflow_value: {
            type: :string,
            description: 'CSV imports only. Column value that marks an amount as an inflow when using custom_column strategy'
          }
        }
      }

      response '201', 'import created' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        let(:body) do
          {
            raw_file_content: "date,amount,name\n01/15/2024,50.00,New Transaction",
            type: 'TransactionImport',
            account_id: account.id,
            date_col_label: 'date',
            amount_col_label: 'amount',
            name_col_label: 'name'
          }
        end

        run_test!
      end

      response '201', 'PDF import created' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        let(:body) do
          {
            type: 'PdfImport',
            account_id: account.id,
            file: Rack::Test::UploadedFile.new(Rails.root.join('test/fixtures/files/imports/sample_bank_statement.pdf'), 'application/pdf')
          }
        end

        run_test!
      end

      response '422', 'validation error or publish rejection' do
        schema oneOf: [
          { '$ref' => '#/components/schemas/ErrorResponse' },
          { '$ref' => '#/components/schemas/ErrorResponseWithImportId' }
        ]

        let(:body) do
          {
            raw_file_content: 'x' * (11 * 1024 * 1024), # 11MB, exceeds MAX_CSV_SIZE
            type: 'TransactionImport'
          }
        end

        run_test!
      end

      response '500', 'import uploaded but publish enqueue failed' do
        schema '$ref' => '#/components/schemas/ErrorResponseWithImportId'

        before do
          allow(ImportJob).to receive(:perform_later).and_raise(StandardError, 'queue offline')
        end

        let(:body) do
          {
            raw_file_content: {
              type: 'Account',
              data: {
                id: 'account_1',
                name: 'Checking',
                balance: '100',
                currency: 'USD',
                accountable_type: 'Depository'
              }
            }.to_json,
            type: 'SureImport',
            publish: 'true'
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'

    get 'Retrieve an import' do
      description 'Retrieve detailed information about a specific import, including configuration, row statistics, SureImport readback verification, and PdfImport processing details when available.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { pending_import.id }

      response '200', 'import retrieved' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update import account assignment' do
      description 'Assign or clear the account used by an import. For PDF imports, assigning an account also links the backing account statement.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          import: {
            type: :object,
            properties: {
              account_id: { type: :string, format: :uuid, nullable: true }
            },
            required: %w[account_id]
          }
        },
        required: %w[import]
      }

      let(:id) { pending_import.id }
      let(:body) { { import: { account_id: account.id } } }

      response '200', 'import account assignment updated' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'import or account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { import: { account_id: SecureRandom.uuid } } }

        run_test!
      end
    end

    delete 'Delete an import' do
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { pending_import.id }

      response '200', 'import deleted' do
        schema '$ref' => '#/components/schemas/DeleteResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

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

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}/sample_csv' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'

    get 'Download sample CSV for an import' do
      description 'Download the import-type-specific sample CSV template used by the web upload flow. Available for CSV-backed import types.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'text/csv', 'application/json'

      let(:id) { pending_import.id }

      response '200', 'sample CSV downloaded' do
        schema type: :string

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '422', 'sample CSV unsupported for import type' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { qif_import.id }

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}/publish' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'

    post 'Publish an import' do
      description 'Queue a configured import for processing.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { pending_import.id }

      response '202', 'import publish queued' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        before do
          allow_any_instance_of(Import).to receive(:publish_later).and_return(true)
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

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

      response '422', 'import not publishable' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow_any_instance_of(Import).to receive(:publish_later).and_raise(StandardError, 'Import is not publishable')
        end

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}/revert' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'

    post 'Revert an import' do
      description 'Queue a completed import for revert.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { complete_import.id }

      response '202', 'import revert queued' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        before do
          allow_any_instance_of(Import).to receive(:revert_later).and_return(true)
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

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

      response '422', 'import not revertable' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow_any_instance_of(Import).to receive(:revert_later).and_raise(StandardError, 'Import is not revertable')
        end

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}/configuration' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'

    patch 'Update import configuration' do
      description 'Update CSV column mapping configuration. When refresh_only is omitted or false, rows are regenerated and mappings are resynced.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          refresh_only: { type: :boolean, description: 'Only update rows_to_skip without regenerating rows.' },
          import: {
            type: :object,
            properties: {
              date_col_label: { type: :string },
              amount_col_label: { type: :string },
              name_col_label: { type: :string },
              category_col_label: { type: :string },
              tags_col_label: { type: :string },
              account_col_label: { type: :string },
              qty_col_label: { type: :string },
              ticker_col_label: { type: :string },
              exchange_operating_mic_col_label: { type: :string },
              price_col_label: { type: :string },
              entity_type_col_label: { type: :string },
              notes_col_label: { type: :string },
              currency_col_label: { type: :string },
              date_format: { type: :string },
              number_format: { type: :string },
              signage_convention: { type: :string, enum: %w[inflows_positive inflows_negative] },
              amount_type_strategy: { type: :string, enum: %w[signed_amount custom_column] },
              amount_type_identifier_value: { type: :string },
              amount_type_inflow_value: { type: :string },
              rows_to_skip: { type: :integer, minimum: 0 }
            }
          }
        }
      }

      let(:id) { pending_import.id }
      let(:body) do
        {
          import: {
            date_col_label: 'date',
            amount_col_label: 'amount',
            name_col_label: 'name',
            date_format: '%m/%d/%Y',
            rows_to_skip: 0
          }
        }
      end

      response '200', 'import configuration updated' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}/apply_template' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'

    post 'Apply suggested import template' do
      description 'Copy column/date/number configuration from the most recent completed import for the same account and import type.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { pending_import.id }

      response '200', 'suggested import template applied' do
        schema '$ref' => '#/components/schemas/ImportResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'no suggested template found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:template_less_account) do
          Account.create!(
            family: family,
            name: 'Template-less Checking',
            balance: 0,
            currency: 'USD',
            accountable: Depository.new
          )
        end
        let(:id) do
          family.imports.create!(
            type: 'TransactionImport',
            status: 'pending',
            account: template_less_account,
            raw_file_str: "date,amount,name\n01/10/2024,-12.00,Coffee"
          ).id
        end

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}/qif_category_selection' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'QIF import ID'

    get 'Get QIF category selection summary' do
      description 'Return detected QIF date formats, category counts, tag counts, and split transaction warnings before publishing a QIF import.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { qif_import.id }

      response '200', 'QIF category selection loaded' do
        schema '$ref' => '#/components/schemas/QifCategorySelectionResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'unsupported import type' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { pending_import.id }

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update QIF category selection' do
      description 'Apply the selected QIF date format, categories, and tags. Omitted categories or tags arrays keep the current row values.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          qif_category_selection: {
            type: :object,
            properties: {
              date_format: {
                type: :string,
                description: 'One of the date format values returned by the GET endpoint.'
              },
              categories: {
                type: :array,
                items: { type: :string },
                description: 'Category names to keep. Omit to keep all current categories; send an empty array to clear all categories.'
              },
              tags: {
                type: :array,
                items: { type: :string },
                description: 'Tag names to keep. Omit to keep all current tags; send an empty array to clear all tags.'
              }
            }
          }
        }
      }

      let(:id) { qif_import.id }
      let(:body) do
        {
          qif_category_selection: {
            categories: [ 'Groceries' ],
            tags: [ 'Weekly' ]
          }
        }
      end

      response '200', 'QIF category selection updated' do
        schema '$ref' => '#/components/schemas/QifCategorySelectionResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '422', 'invalid date format' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { qif_category_selection: { date_format: '%Y/%m/%d' } } }

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}/rows/{row_id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'
    parameter name: :row_id, in: :path, type: :string, required: true, description: 'Import row ID'

    patch 'Update an import row' do
      description 'Edit sanitized row fields and resync import mappings.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          import_row: {
            type: :object,
            properties: {
              account: { type: :string },
              date: { type: :string },
              qty: { type: :string },
              ticker: { type: :string },
              exchange_operating_mic: { type: :string },
              price: { type: :string },
              amount: { type: :string },
              currency: { type: :string },
              name: { type: :string },
              category: { type: :string },
              tags: { type: :string },
              entity_type: { type: :string },
              notes: { type: :string },
              active: { type: :boolean },
              effective_date: { type: :string },
              conditions: { type: :string },
              actions: { type: :string }
            }
          }
        }
      }

      let(:id) { pending_import.id }
      let(:row_id) { import_row.id }
      let(:body) { { import_row: { name: 'Edited Transaction', category: 'Edited Category' } } }

      response '200', 'import row updated' do
        schema '$ref' => '#/components/schemas/ImportRowDiagnosticResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'import row not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:row_id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}/mappings/{mapping_id}' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'
    parameter name: :mapping_id, in: :path, type: :string, required: true, description: 'Import mapping ID'

    patch 'Update an import mapping' do
      description 'Resolve an import mapping to an existing family resource, mark it for create-when-empty, or set a scalar mapping value such as account type.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          import_mapping: {
            type: :object,
            properties: {
              mappable_id: {
                type: :string,
                description: 'Existing family resource ID, blank to clear, or internal_new_resource to create during publish.'
              },
              value: { type: :string, description: 'Scalar mapping value for account type mappings.' }
            }
          }
        }
      }

      let(:id) { pending_import.id }
      let(:mapping_id) { category_mapping.id }
      let(:body) { { import_mapping: { mappable_id: mapped_category.id } } }

      response '200', 'import mapping updated' do
        schema '$ref' => '#/components/schemas/ImportMappingResponse'

        run_test!
      end

      response '403', 'forbidden - api key missing read_write scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'import mapping not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:mapping_id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/imports/{id}/rows' do
    parameter name: :id, in: :path, type: :string, required: true, description: 'Import ID'

    get 'List import row diagnostics' do
      description 'List sanitized import rows with validation errors and mapping resolution state.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'

      let(:id) { pending_import.id }

      response '200', 'import rows listed' do
        schema '$ref' => '#/components/schemas/ImportRowDiagnosticCollection'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { nil }

        run_test!
      end

      response '403', 'insufficient scope' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }

        run_test!
      end

      response '404', 'import not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end

      response '500', 'internal server error' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          allow_any_instance_of(Import::Row).to receive(:valid?).and_raise(StandardError, 'validation down')
        end

        run_test!
      end
    end
  end

  path '/api/v1/imports/preflight' do
    post 'Validate import content without creating an import' do
      description 'Validate CSV or Sure NDJSON import content and return counts, headers, warnings, and validation errors without persisting an import or enqueueing jobs. CSV content is limited to 10MB.'
      tags 'Imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json', 'multipart/form-data'
      produces 'application/json'

      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          raw_file_content: {
            type: :string,
            description: 'Raw CSV or Sure NDJSON content as a string. CSV content is limited to 10MB.'
          },
          file: {
            type: :string,
            format: :binary,
            description: 'CSV or Sure NDJSON upload when using multipart/form-data. CSV files are limited to 10MB.'
          },
          type: {
            type: :string,
            enum: Import::TYPES,
            description: 'Import type to validate (defaults to TransactionImport)'
          },
          account_id: {
            type: :string,
            format: :uuid,
            description: 'Account ID used for account-scoped CSV import validation'
          },
          date_col_label: { type: :string, description: 'CSV imports only. Header name for the date column' },
          amount_col_label: { type: :string, description: 'CSV imports only. Header name for the amount column' },
          name_col_label: { type: :string, description: 'CSV imports only. Header name for the transaction name column' },
          category_col_label: { type: :string, description: 'CSV imports only. Header name for the category column' },
          tags_col_label: { type: :string, description: 'CSV imports only. Header name for the tags column' },
          notes_col_label: { type: :string, description: 'CSV imports only. Header name for the notes column' },
          account_col_label: { type: :string, description: 'CSV imports only. Header name for the account column' },
          qty_col_label: { type: :string, description: 'CSV trade imports only. Header name for the quantity column' },
          ticker_col_label: { type: :string, description: 'CSV trade imports only. Header name for the ticker column' },
          price_col_label: { type: :string, description: 'CSV trade imports only. Header name for the price column' },
          entity_type_col_label: { type: :string, description: 'CSV imports only. Header name for the entity type column' },
          currency_col_label: { type: :string, description: 'CSV imports only. Header name for the currency column' },
          exchange_operating_mic_col_label: { type: :string, description: 'CSV trade imports only. Header name for the exchange operating MIC column' },
          date_format: { type: :string, description: 'CSV imports only. Date format pattern' },
          number_format: {
            type: :string,
            enum: [ '1,234.56', '1.234,56', '1 234,56', '1,234' ],
            description: 'CSV imports only. Number format for parsing amounts'
          },
          signage_convention: {
            type: :string,
            enum: %w[inflows_positive inflows_negative],
            description: 'CSV imports only. How to interpret positive/negative amounts'
          },
          col_sep: {
            type: :string,
            enum: [ ',', ';' ],
            description: 'CSV imports only. Column separator'
          },
          rows_to_skip: {
            type: :integer,
            minimum: 0,
            description: 'CSV imports only. Number of leading rows to skip before reading headers'
          },
          amount_type_strategy: {
            type: :string,
            enum: %w[signed_amount custom_column],
            description: 'CSV imports only. Amount parsing strategy'
          },
          amount_type_inflow_value: {
            type: :string,
            description: 'CSV imports only. Column value that marks an amount as an inflow when using custom_column strategy'
          }
        }
      }

      response '200', 'import content preflighted' do
        schema '$ref' => '#/components/schemas/ImportPreflightResponse'

        let(:body) do
          {
            raw_file_content: "date,amount,name\n01/15/2024,50.00,New Transaction",
            type: 'TransactionImport',
            account_id: account.id,
            date_col_label: 'date',
            amount_col_label: 'amount',
            name_col_label: 'name'
          }
        end

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        let(:body) { { raw_file_content: "date,amount\n01/15/2024,50.00" } }

        run_test!
      end

      response '422', 'missing or invalid content' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:body) { { type: 'SureImport' } }

        run_test!
      end

      response '404', 'account not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:body) do
          {
            raw_file_content: "date,amount,name\n01/15/2024,50.00,New Transaction",
            account_id: SecureRandom.uuid
          }
        end

        run_test!
      end
    end
  end
end
