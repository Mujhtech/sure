# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Transactions', type: :request do
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

  let(:merchant) do
    family.merchants.create!(name: 'Whole Foods')
  end

  let(:tag) do
    family.tags.create!(name: 'Essential', color: '#2196F3')
  end

  let!(:transaction) do
    entry = account.entries.create!(
      name: 'Grocery shopping',
      date: Date.current,
      amount: 75.50,
      currency: 'USD',
      entryable: Transaction.new(
        category: category,
        merchant: merchant
      )
    )
    entry.transaction.tags << tag
    entry.transaction
  end

  let!(:another_transaction) do
    entry = account.entries.create!(
      name: 'Coffee',
      date: Date.current - 1.day,
      amount: 5.00,
      currency: 'USD',
      entryable: Transaction.new
    )
    entry.transaction
  end

  let(:investment_account) do
    Account.create!(
      family: family,
      owner: user,
      name: 'Investment Account',
      balance: 1000,
      currency: 'USD',
      accountable: Investment.create!
    )
  end

  let(:security) do
    Security.create!(
      ticker: 'AAPL',
      name: 'Apple Inc.',
      country_code: 'US'
    )
  end

  let(:investment_transaction) do
    investment_account.entries.create!(
      name: 'Brokerage buy',
      date: Date.current,
      amount: 250.00,
      currency: 'USD',
      entryable: Transaction.new
    ).transaction
  end

  path '/api/v1/transactions' do
    get 'List transactions' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      description 'Returns global ledger history for accessible accounts, including disabled accounts but excluding accounts pending deletion.'
      produces 'application/json'
      parameter name: :page, in: :query, type: :integer, required: false,
                description: 'Page number (default: 1)'
      parameter name: :per_page, in: :query, type: :integer, required: false,
                description: 'Items per page (default: 25, max: 100)'
      parameter name: :account_id, in: :query, type: :string, required: false,
                description: 'Filter by account ID'
      parameter name: :category_id, in: :query, type: :string, required: false,
                description: 'Filter by category ID'
      parameter name: :merchant_id, in: :query, type: :string, required: false,
                description: 'Filter by merchant ID'
      parameter name: :start_date, in: :query, required: false,
                description: 'Filter transactions from this date',
                schema: { type: :string, format: :date }
      parameter name: :end_date, in: :query, required: false,
                description: 'Filter transactions until this date',
                schema: { type: :string, format: :date }
      parameter name: :min_amount, in: :query, type: :number, required: false,
                description: 'Filter by minimum amount'
      parameter name: :max_amount, in: :query, type: :number, required: false,
                description: 'Filter by maximum amount'
      parameter name: :type, in: :query, required: false,
                description: 'Filter by transaction type',
                schema: { type: :string, enum: %w[income expense] }
      parameter name: :search, in: :query, type: :string, required: false,
                description: 'Search by name, notes, or merchant name'
      parameter name: :account_ids, in: :query, required: false,
                description: 'Filter by multiple account IDs',
                schema: { type: :array, items: { type: :string } }
      parameter name: :category_ids, in: :query, required: false,
                description: 'Filter by multiple category IDs',
                schema: { type: :array, items: { type: :string } }
      parameter name: :merchant_ids, in: :query, required: false,
                description: 'Filter by multiple merchant IDs',
                schema: { type: :array, items: { type: :string } }
      parameter name: :tag_ids, in: :query, required: false,
                description: 'Filter by tag IDs',
                schema: { type: :array, items: { type: :string } }

      response '200', 'transactions listed' do
        schema '$ref' => '#/components/schemas/TransactionCollection'

        run_test!
      end

      response '200', 'transactions filtered by account' do
        schema '$ref' => '#/components/schemas/TransactionCollection'

        let(:account_id) { account.id }

        run_test!
      end

      response '200', 'transactions filtered by date range' do
        schema '$ref' => '#/components/schemas/TransactionCollection'

        let(:start_date) { (Date.current - 7.days).to_s }
        let(:end_date) { Date.current.to_s }

        run_test!
      end
    end

    post 'Create transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transaction: {
            type: :object,
            properties: {
              account_id: { type: :string, format: :uuid, description: 'Account ID (required)' },
              date: { type: :string, format: :date, description: 'Transaction date' },
              amount: { type: :number, description: 'Transaction amount' },
              name: { type: :string, description: 'Transaction name/description' },
              description: { type: :string, description: 'Alternative to name field' },
              notes: { type: :string, description: 'Additional notes' },
              currency: { type: :string, description: 'Currency code (defaults to family currency)' },
              category_id: { type: :string, format: :uuid, description: 'Category ID' },
              merchant_id: { type: :string, format: :uuid, description: 'Merchant ID' },
              nature: { type: :string, enum: %w[income expense inflow outflow], description: 'Transaction nature (determines sign)' },
              external_id: { type: :string, description: 'Optional external idempotency key scoped to account and source' },
              source: { type: :string, description: 'Optional source namespace for external_id. Requires external_id and defaults to api when external_id is provided' },
              tag_ids: { type: :array, items: { type: :string, format: :uuid }, description: 'Array of tag IDs' }
            },
            required: %w[account_id date amount name]
          }
        },
        required: %w[transaction]
      }

      let(:body) do
        {
          transaction: {
            account_id: account.id,
            date: Date.current.to_s,
            amount: 50.00,
            name: 'Test purchase',
            nature: 'expense',
            category_id: category.id,
            merchant_id: merchant.id
          }
        }
      end

      response '201', 'transaction created' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end

      response '200', 'transaction already exists for external idempotency key' do
        schema '$ref' => '#/components/schemas/Transaction'

        let(:body) do
          {
            transaction: {
              account_id: account.id,
              date: Date.current.to_s,
              amount: 50.00,
              name: 'Test purchase',
              nature: 'expense',
              external_id: 'docs-import-transaction-1',
              source: 'external_import'
            }
          }
        end

        before do
          account.entries.create!(
            name: 'Test purchase',
            date: Date.current,
            amount: 50.00,
            currency: 'USD',
            external_id: 'docs-import-transaction-1',
            source: 'external_import',
            entryable: Transaction.new
          )
        end

        run_test!
      end

      response '422', 'validation error - missing account_id' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            transaction: {
              date: Date.current.to_s,
              amount: 50.00,
              name: 'Test purchase'
            }
          }
        end

        run_test!
      end

      response '422', 'validation error - missing required fields' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            transaction: {
              account_id: account.id
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/transactions/bulk_update' do
    patch 'Bulk update transactions' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Updates multiple transaction entries. Pass entry_id values from transaction responses; split parent entries are skipped.'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          bulk_update: {
            type: :object,
            properties: {
              entry_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                description: 'Transaction entry IDs to update'
              },
              date: { type: :string, format: :date },
              notes: { type: :string },
              name: { type: :string },
              category_id: { type: :string, format: :uuid },
              merchant_id: { type: :string, format: :uuid },
              tag_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                description: 'Omit to preserve tags; pass [] to clear tags.'
              }
            },
            required: %w[entry_ids]
          }
        },
        required: %w[bulk_update]
      }

      let(:body) do
        {
          bulk_update: {
            entry_ids: [ transaction.entry.id, another_transaction.entry.id ],
            name: 'Updated from mobile',
            tag_ids: [ tag.id ]
          }
        }
      end

      response '200', 'transactions updated' do
        schema '$ref' => '#/components/schemas/BulkOperationResponse'

        run_test!
      end

      response '422', 'validation error - missing entry ids' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            bulk_update: {
              name: 'Updated from mobile'
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/transactions/bulk_delete' do
    delete 'Bulk delete transactions' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Deletes multiple transaction entries from writable accounts. Split child entries are skipped.'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          bulk_delete: {
            type: :object,
            properties: {
              entry_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                description: 'Transaction entry IDs to delete'
              }
            },
            required: %w[entry_ids]
          }
        },
        required: %w[bulk_delete]
      }

      let(:body) do
        {
          bulk_delete: {
            entry_ids: [ another_transaction.entry.id ]
          }
        }
      end

      response '200', 'transactions deleted' do
        schema '$ref' => '#/components/schemas/BulkOperationResponse'

        run_test!
      end

      response '422', 'validation error - missing entry ids' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            bulk_delete: {
              entry_ids: []
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{id}/duplicate_candidates' do
    parameter name: :id, in: :path, schema: { type: :string, format: :uuid }, required: true, description: 'Pending transaction ID'
    parameter name: :limit, in: :query, type: :integer, required: false, description: 'Max candidates to return (default: 10, max: 50)'
    parameter name: :offset, in: :query, type: :integer, required: false, description: 'Pagination offset'

    get 'List duplicate merge candidates' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { transaction.id }
      let(:limit) { 10 }
      let(:offset) { 0 }

      before do
        transaction.update!(extra: { 'plaid' => { 'pending' => true } })
      end

      response '200', 'duplicate candidates listed' do
        schema '$ref' => '#/components/schemas/TransactionDuplicateCandidatesResponse'

        run_test!
      end

      response '422', 'transaction is not pending' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          transaction.update!(extra: {})
        end

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{transaction_id}/transfer_match' do
    parameter name: :transaction_id, in: :path, schema: { type: :string, format: :uuid }, required: true, description: 'Transaction ID'

    let(:transfer_target_account) do
      family.accounts.create!(
        name: 'Savings Account',
        balance: 2500,
        currency: 'USD',
        accountable: Depository.create!
      )
    end

    let!(:transfer_source_entry) do
      account.entries.create!(
        name: 'Transfer to savings',
        date: Date.current,
        amount: 75,
        currency: 'USD',
        entryable: Transaction.new
      )
    end

    let!(:transfer_target_entry) do
      transfer_target_account.entries.create!(
        name: 'Transfer from checking',
        date: Date.current + 1.day,
        amount: -75,
        currency: 'USD',
        entryable: Transaction.new
      )
    end

    let(:transaction_id) { transfer_source_entry.transaction.id }

    get 'List transfer match options' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :date_window, in: :query, type: :integer, required: false,
                description: 'Candidate date window in days. Defaults to 30.'

      response '200', 'transfer match options listed' do
        schema '$ref' => '#/components/schemas/TransferMatchOptions'

        run_test!
      end

      response '422', 'invalid date window' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:date_window) { 'soon' }

        run_test!
      end
    end

    post 'Create transfer match' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Matches an existing transaction to another opposite transaction, or creates the missing transfer side in a target account.'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transfer_match: {
            type: :object,
            properties: {
              method: {
                type: :string,
                enum: %w[existing new],
                description: 'existing matches another entry; new creates the missing transaction side.'
              },
              matched_entry_id: { type: :string, format: :uuid, description: 'Required for method=existing.' },
              target_account_id: { type: :string, format: :uuid, description: 'Required for method=new.' }
            },
            required: %w[method]
          }
        },
        required: %w[transfer_match]
      }

      let(:body) do
        {
          transfer_match: {
            method: 'existing',
            matched_entry_id: transfer_target_entry.id
          }
        }
      end

      response '201', 'transfer match created' do
        schema '$ref' => '#/components/schemas/TransferDecision'

        run_test!
      end

      response '422', 'invalid transfer match method' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            transfer_match: {
              method: 'later'
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{id}/merge_duplicate' do
    parameter name: :id, in: :path, schema: { type: :string, format: :uuid }, required: true, description: 'Pending transaction ID'

    post 'Merge duplicate transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Merges a pending transaction into its suggested posted match. Optionally pass posted_entry_id to perform a manual match.'

      parameter name: :body, in: :body, required: false, schema: {
        type: :object,
        properties: {
          duplicate: {
            type: :object,
            properties: {
              posted_entry_id: { type: :string, format: :uuid }
            }
          }
        }
      }

      let(:id) { transaction.id }
      let(:body) do
        {
          duplicate: {
            posted_entry_id: another_transaction.entry.id
          }
        }
      end

      before do
        transaction.update!(extra: { 'plaid' => { 'pending' => true } })
      end

      response '200', 'duplicate merged' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end

      response '422', 'invalid posted entry' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) do
          {
            duplicate: {
              posted_entry_id: SecureRandom.uuid
            }
          }
        end

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{id}/dismiss_duplicate' do
    parameter name: :id, in: :path, schema: { type: :string, format: :uuid }, required: true, description: 'Transaction ID'

    post 'Dismiss duplicate suggestion' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { transaction.id }

      before do
        transaction.update!(
          extra: {
            'potential_posted_match' => {
              'entry_id' => another_transaction.entry.id,
              'reason' => 'manual_match',
              'confidence' => 'high'
            }
          }
        )
      end

      response '200', 'duplicate suggestion dismissed' do
        schema '$ref' => '#/components/schemas/GenericMessageResponse'

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{id}/mark_as_recurring' do
    parameter name: :id, in: :path, schema: { type: :string, format: :uuid }, required: true, description: 'Transaction ID'

    post 'Mark transaction as recurring' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { transaction.id }

      response '201', 'recurring transaction created' do
        schema '$ref' => '#/components/schemas/RecurringTransaction'

        run_test!
      end

      response '409', 'recurring transaction already exists' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        before do
          RecurringTransaction.create_from_transaction(transaction)
        end

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{id}/convert_to_trade' do
    parameter name: :id, in: :path, schema: { type: :string, format: :uuid }, required: true, description: 'Transaction ID'

    post 'Convert transaction to trade' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Converts an investment-account transaction into a trade entry and excludes the original transaction.'

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          trade_conversion: {
            type: :object,
            properties: {
              security_id: { type: :string, format: :uuid, description: 'Existing security ID to trade.' },
              ticker: { type: :string, description: 'Ticker or combobox token to resolve when security_id is not provided.' },
              custom_ticker: { type: :string, description: 'Manual ticker fallback when security_id is not provided.' },
              exchange_operating_mic: { type: :string, description: 'Optional exchange MIC for ticker resolution.' },
              qty: { type: :number, format: :float, description: 'Quantity. Required when price is omitted.' },
              price: { type: :number, format: :float, description: 'Price. Required when qty is omitted.' },
              investment_activity_label: { type: :string, enum: %w[Buy Sell], description: 'Optional trade direction. Defaults from transaction amount sign.' },
              trade_name: { type: :string, description: 'Optional custom trade entry name.' }
            }
          }
        }
      }

      let(:id) { investment_transaction.id }
      let(:body) do
        {
          trade_conversion: {
            security_id: security.id,
            qty: 5,
            investment_activity_label: 'Buy'
          }
        }
      end

      response '201', 'trade created from transaction' do
        schema '$ref' => '#/components/schemas/Trade'

        run_test!
      end

      response '422', 'not an investment account' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { transaction.id }

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{id}/unlock' do
    parameter name: :id, in: :path, schema: { type: :string, format: :uuid }, required: true, description: 'Transaction ID'

    post 'Unlock transaction for sync' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { transaction.id }

      before do
        transaction.entry.mark_user_modified!
        transaction.entry.lock_saved_attributes!
      end

      response '200', 'transaction unlocked' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end
    end
  end

  path '/api/v1/transactions/categorize' do
    get 'Retrieve next uncategorized transaction group' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      description 'Returns the next uncategorized transaction group, category options, and total uncategorized count for the Quick Categorize workflow.'
      parameter name: :position, in: :query, type: :integer, required: false,
                description: 'Zero-based group offset to retrieve.'

      response '200', 'categorization group retrieved' do
        schema '$ref' => '#/components/schemas/TransactionCategorizationShowResponse'

        run_test!
      end
    end

    post 'Categorize a transaction group' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Assigns a category to selected uncategorized ledger entries and can create the matching transaction rule used by the web Quick Categorize wizard. Account owners, full-control collaborators, and read-write collaborators can categorize entries.'
      parameter name: :body, in: :body, required: true, schema: {
        '$ref' => '#/components/schemas/TransactionCategorizationCreateRequest'
      }

      let(:body) do
        {
          categorization: {
            entry_ids: [ another_transaction.entry.id ],
            all_entry_ids: [ another_transaction.entry.id ],
            category_id: category.id,
            create_rule: true,
            grouping_key: another_transaction.entry.name,
            transaction_type: 'expense'
          }
        }
      end

      response '200', 'transactions categorized' do
        schema '$ref' => '#/components/schemas/TransactionCategorizationCreateResponse'

        run_test!
      end

      response '422', 'missing entry ids' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { categorization: { category_id: category.id } } }

        run_test!
      end
    end
  end

  path '/api/v1/transactions/categorize/preview_rule' do
    get 'Preview a categorization rule' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      description 'Returns uncategorized entries that would match a transaction-name rule before creating it.'
      parameter name: :filter, in: :query, type: :string, required: true,
                description: 'Transaction name text to match.'
      parameter name: :transaction_type, in: :query, required: false,
                schema: { type: :string, enum: %w[income expense] }
      parameter name: :limit, in: :query, type: :integer, required: false,
                description: 'Maximum entries returned, default 100, max 250.'
      parameter name: :offset, in: :query, type: :integer, required: false,
                description: 'Offset into matching entries.'

      let(:filter) { another_transaction.entry.name }
      let(:transaction_type) { 'expense' }

      response '200', 'rule preview returned' do
        schema '$ref' => '#/components/schemas/TransactionCategorizationPreviewResponse'

        run_test!
      end
    end
  end

  path '/api/v1/transactions/categorize/assign_entry' do
    patch 'Categorize a single transaction entry' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Assigns a category to one entry from a categorization group and returns the remaining uncategorized entries from that group. Account owners, full-control collaborators, and read-write collaborators can categorize entries.'
      parameter name: :body, in: :body, required: true, schema: {
        '$ref' => '#/components/schemas/TransactionCategorizationAssignmentRequest'
      }

      let(:body) do
        {
          assignment: {
            entry_id: another_transaction.entry.id,
            all_entry_ids: [ another_transaction.entry.id ],
            category_id: category.id
          }
        }
      end

      response '200', 'transaction entry categorized' do
        schema '$ref' => '#/components/schemas/TransactionCategorizationAssignmentResponse'

        run_test!
      end

      response '422', 'missing category id' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:body) { { assignment: { entry_id: another_transaction.entry.id } } }

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{id}' do
    parameter name: :id, in: :path, schema: { type: :string, format: :uuid }, required: true, description: 'Transaction ID'

    get 'Retrieve a transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { transaction.id }

      response '200', 'transaction retrieved' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    patch 'Update a transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Updates a transaction. Account owners and full-control collaborators can edit all fields; read-write collaborators can update annotation fields only: notes, category_id, merchant_id, and tag_ids.'

      let(:id) { transaction.id }

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transaction: {
            type: :object,
            properties: {
              date: { type: :string, format: :date },
              amount: { type: :number },
              name: { type: :string },
              description: { type: :string, description: 'Alternative to name field' },
              notes: { type: :string },
              currency: { type: :string, description: 'Currency code' },
              category_id: { type: :string, format: :uuid },
              merchant_id: { type: :string, format: :uuid },
              nature: { type: :string, enum: %w[income expense inflow outflow] },
              tag_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                description: 'Array of tag IDs to assign. Omit to preserve existing tags; use [] to clear all tags.'
              }
            }
          }
        }
      }

      let(:body) do
        {
          transaction: {
            name: 'Updated grocery shopping',
            notes: 'Weekly groceries'
          }
        }
      end

      response '200', 'transaction updated' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end

    delete 'Delete a transaction' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      let(:id) { another_transaction.id }

      response '200', 'transaction deleted' do
        schema '$ref' => '#/components/schemas/DeleteResponse'

        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path '/api/v1/transactions/{id}/tags' do
    parameter name: :id, in: :path, schema: { type: :string, format: :uuid }, required: true, description: 'Transaction ID'

    patch 'Update transaction tags' do
      tags 'Transactions'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      description 'Replaces the transaction tag set. Tags are scoped to the current family; pass [] to clear tags. Account owners, full-control collaborators, and read-write collaborators can annotate tags.'

      let(:id) { transaction.id }

      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          transaction: {
            type: :object,
            properties: {
              tag_ids: {
                type: :array,
                items: { type: :string, format: :uuid },
                description: 'Tag IDs to assign. Use [] to clear all tags.'
              }
            },
            required: %w[tag_ids]
          }
        },
        required: %w[transaction]
      }

      let(:body) do
        {
          transaction: {
            tag_ids: [ tag.id ]
          }
        }
      end

      response '200', 'transaction tags updated' do
        schema '$ref' => '#/components/schemas/Transaction'

        run_test!
      end

      response '404', 'transaction not found' do
        schema '$ref' => '#/components/schemas/ErrorResponse'

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
