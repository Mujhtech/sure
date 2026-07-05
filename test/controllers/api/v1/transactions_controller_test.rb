# frozen_string_literal: true

require "test_helper"

class Api::V1::TransactionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = @family.accounts.first
    @transaction = @family.transactions.first

    # Destroy existing active API keys to avoid validation errors
    @user.api_keys.active.destroy_all

    # Create fresh API keys instead of using fixtures to avoid parallel test conflicts (rate limiting in test)
    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read-Only Key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"  # Use different source to allow multiple keys
    )

    # Clear any existing rate limit data
    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")
  end

  # INDEX action tests
  test "should get index with valid API key" do
    get api_v1_transactions_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data.key?("transactions")
    assert response_data.key?("pagination")

    # Agent-friendly numeric fields (validate type + sign invariants)
    first = response_data["transactions"].first
    assert_amount_cents_fields(first)
    assert response_data["pagination"].key?("page")
    assert response_data["pagination"].key?("per_page")
    assert response_data["pagination"].key?("total_count")
    assert response_data["pagination"].key?("total_pages")
  end

  test "should include converted amounts in family currency" do
    @family.update!(currency: "NGN")
    transaction_date = Date.current - 7.days
    account = @family.accounts.create!(
      name: "USD Converted Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    entry = account.entries.create!(
      name: "USD converted summary expense",
      amount: 10,
      currency: "USD",
      date: transaction_date,
      entryable: Transaction.new
    )
    ExchangeRate.where(from_currency: "USD", to_currency: "NGN", date: transaction_date).delete_all
    ExchangeRate.create!(
      from_currency: "USD",
      to_currency: "NGN",
      date: transaction_date,
      rate: 1500
    )

    get api_v1_transactions_url,
        params: { search: "USD converted summary expense" },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    transaction = response_data.fetch("transactions").find { |txn| txn["id"] == entry.transaction.id }

    assert_not_nil transaction
    assert_equal "USD", transaction["currency"]
    assert_equal(-1000, transaction["signed_amount_cents"])
    assert_equal "NGN", transaction["converted_currency"]
    assert_equal(-1_500_000, transaction["converted_amount_cents"])
  end

  test "should get index with read-only API key" do
    get api_v1_transactions_url, headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "should filter transactions by account_id" do
    get api_v1_transactions_url, params: { account_id: @account.id }, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    response_data["transactions"].each do |transaction|
      assert_equal @account.id, transaction["account"]["id"]
    end
  end

  test "should include disabled account transactions in index history" do
    disabled_transaction = create_disabled_account_transaction(name: "Closed Account Grocery")

    get api_v1_transactions_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    transaction_ids = response_data["transactions"].map { |transaction| transaction["id"] }
    assert_includes transaction_ids, disabled_transaction.id
  end

  test "should exclude pending deletion account transactions from index history" do
    pending_deletion_transaction = create_account_transaction(
      status: "pending_deletion",
      name: "Pending Delete Account Grocery"
    )

    get api_v1_transactions_url, headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    transaction_ids = response_data["transactions"].map { |transaction| transaction["id"] }
    assert_not_includes transaction_ids, pending_deletion_transaction.id
  end

  test "should filter disabled account transactions by account_id" do
    disabled_transaction = create_disabled_account_transaction(name: "Closed Account Filter")
    disabled_account = disabled_transaction.entry.account

    get api_v1_transactions_url,
        params: { account_id: disabled_account.id },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal [ disabled_transaction.id ], response_data["transactions"].map { |transaction| transaction["id"] }
  end

  test "should filter transactions by date range" do
    start_date = 1.month.ago.to_date
    end_date = Date.current

    get api_v1_transactions_url,
        params: { start_date: start_date, end_date: end_date },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    response_data["transactions"].each do |transaction|
      transaction_date = Date.parse(transaction["date"])
      assert transaction_date >= start_date
      assert transaction_date <= end_date
    end
  end

  test "should filter disabled account transactions by date range" do
    disabled_transaction = create_disabled_account_transaction(
      name: "Closed Account Date Range",
      date: Date.current - 3.days
    )

    get api_v1_transactions_url,
        params: { start_date: Date.current - 4.days, end_date: Date.current - 2.days },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    transaction_ids = response_data["transactions"].map { |transaction| transaction["id"] }
    assert_includes transaction_ids, disabled_transaction.id
  end

  test "should search transactions" do
    # Create a transaction with a specific name for testing
    entry = @account.entries.create!(
      name: "Test Coffee Purchase",
      amount: 5.50,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    get api_v1_transactions_url,
        params: { search: "Coffee" },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    found_transaction = response_data["transactions"].find { |t| t["id"] == entry.transaction.id }
    assert_not_nil found_transaction, "Should find the coffee transaction"
  end

  test "should search disabled account transactions" do
    disabled_transaction = create_disabled_account_transaction(name: "Closed Account Coffee")

    get api_v1_transactions_url,
        params: { search: "Closed Account Coffee" },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    found_transaction = response_data["transactions"].find { |transaction| transaction["id"] == disabled_transaction.id }
    assert_not_nil found_transaction, "Should find disabled account transactions in global history search"
  end

  test "should paginate transactions" do
    get api_v1_transactions_url,
        params: { page: 1, per_page: 5 },
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert response_data["transactions"].size <= 5
    assert_equal 1, response_data["pagination"]["page"]
    assert_equal 5, response_data["pagination"]["per_page"]
  end

  test "should reject index request without API key" do
    get api_v1_transactions_url
    assert_response :unauthorized
  end

  test "should reject index request with invalid API key" do
    get api_v1_transactions_url, headers: { "X-Api-Key" => "invalid-key" }
    assert_response :unauthorized
  end

  # SHOW action tests
  test "should show transaction with valid API key" do
    get api_v1_transaction_url(@transaction), headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal @transaction.id, response_data["id"]
    assert response_data.key?("name")
    assert response_data.key?("amount")
    assert_amount_cents_fields(response_data)
    assert response_data.key?("date")
    assert response_data.key?("account")
  end

  test "should show transaction with read-only API key" do
    get api_v1_transaction_url(@transaction), headers: api_headers(@read_only_api_key)
    assert_response :success
  end

  test "should show disabled account transaction" do
    disabled_transaction = create_disabled_account_transaction(name: "Closed Account Show")

    get api_v1_transaction_url(disabled_transaction), headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal disabled_transaction.id, response_data["id"]
    assert_equal disabled_transaction.entry.account_id, response_data["account"]["id"]
  end

  test "should return 404 for valid missing transaction id" do
    get api_v1_transaction_url(SecureRandom.uuid), headers: api_headers(@api_key)
    assert_response :not_found

    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
    assert_equal "Transaction not found", response_data["message"]
  end

  test "should return 404 for malformed id" do
    get api_v1_transaction_url(999999), headers: api_headers(@api_key)
    assert_response :not_found

    response_data = JSON.parse(response.body)
    assert_equal "not_found", response_data["error"]
    assert_equal "Transaction not found", response_data["message"]
  end

  test "should reject show request without API key" do
    get api_v1_transaction_url(@transaction)
    assert_response :unauthorized
  end

  # CREATE action tests
  test "should create transaction with valid parameters" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Test Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense"
      }
    }

    assert_difference("@account.entries.count", 1) do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "Test Transaction", response_data["name"]
    assert_equal @account.id, response_data["account"]["id"]
  end

  test "should create transaction with external idempotency key" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "import-txn-1",
        source: "external_import"
      }
    }

    assert_difference("@account.entries.count", 1) do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "import-txn-1", response_data["external_id"]
    assert_equal "external_import", response_data["source"]

    entry = @account.entries.find_by!(external_id: "import-txn-1", source: "external_import")
    assert_equal response_data["id"], entry.transaction.id
  end

  test "should use default source when external_id provided without source" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "default-source-test"
      }
    }

    assert_difference("@account.entries.count", 1) do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    entry = @account.entries.find_by!(external_id: "default-source-test")
    assert_equal "api", entry.source
    assert_equal "api", response_data["source"]

    assert_no_difference("@account.entries.count") do
      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { name: "Changed Name" }),
           headers: api_headers(@api_key)
    end

    assert_response :ok
  end

  test "should reject source without external idempotency key" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        source: "external_import"
      }
    }

    assert_no_difference("@account.entries.count") do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_equal "Source requires external_id", response_data["message"]
    assert_equal [ "Source requires external_id" ], response_data["errors"]
  end

  test "should return existing transaction for duplicate external idempotency key" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "import-txn-2",
        source: "external_import"
      }
    }

    post api_v1_transactions_url,
         params: transaction_params,
         headers: api_headers(@api_key)
    assert_response :created
    created_data = JSON.parse(response.body)

    assert_no_difference("@account.entries.count") do
      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { name: "Changed Name" }),
           headers: api_headers(@api_key)
    end

    assert_response :ok
    response_data = JSON.parse(response.body)
    assert_equal created_data["id"], response_data["id"]
    assert_equal "Imported Transaction", response_data["name"]
  end

  test "should scope external idempotency keys to account" do
    other_account = @family.accounts.create!(
      name: "Other API Account",
      accountable: Depository.new,
      balance: 0,
      currency: "USD"
    )
    transaction_params = {
      transaction: {
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "shared-import-txn",
        source: "external_import"
      }
    }

    assert_difference("Entry.count", 2) do
      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { account_id: @account.id }),
           headers: api_headers(@api_key)
      assert_response :created

      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { account_id: other_account.id }),
           headers: api_headers(@api_key)
      assert_response :created
    end
  end

  test "should scope external idempotency keys to source" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Imported Transaction",
        amount: 25.00,
        date: Date.current,
        currency: "USD",
        nature: "expense",
        external_id: "shared-source-txn",
        source: "external_import"
      }
    }

    assert_difference("Entry.count", 2) do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
      assert_response :created

      post api_v1_transactions_url,
           params: transaction_params.deep_merge(transaction: { source: "other_import" }),
           headers: api_headers(@api_key)
      assert_response :created
    end

    @account.entries.find_by!(external_id: "shared-source-txn", source: "external_import")
    @account.entries.find_by!(external_id: "shared-source-txn", source: "other_import")
  end

  test "should reject external idempotency key collision with non-transaction entry" do
    @account.entries.create!(
      name: "Existing valuation",
      amount: 100,
      currency: "USD",
      date: Date.current,
      external_id: "import-non-transaction",
      source: "external_import",
      entryable: Valuation.new
    )

    post api_v1_transactions_url,
         params: {
           transaction: {
             account_id: @account.id,
             name: "Imported Transaction",
             amount: 25.00,
             date: Date.current - 1.day,
             currency: "USD",
             nature: "expense",
             external_id: "import-non-transaction",
             source: "external_import"
           }
         },
         headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
  end

  test "should reject create with read-only API key" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Test Transaction",
        amount: 25.00,
        date: Date.current
      }
    }

    post api_v1_transactions_url,
         params: transaction_params,
         headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should reject create with invalid parameters" do
    transaction_params = {
      transaction: {
        # Missing required fields
        name: "Test Transaction"
      }
    }

    post api_v1_transactions_url,
         params: transaction_params,
         headers: api_headers(@api_key)
    assert_response :unprocessable_entity
  end

  test "should reject invalid date on create" do
    transaction_params = {
      transaction: {
        account_id: @account.id,
        name: "Invalid Date Transaction",
        amount: 25.00,
        date: "not-a-date",
        currency: "USD",
        nature: "expense"
      }
    }

    assert_no_difference("@account.entries.count") do
      post api_v1_transactions_url,
           params: transaction_params,
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_equal "Transaction could not be created", response_data["message"]
    assert response_data["errors"].any? { |error| error.match?(/Date/) }
  end

  test "should reject create without API key" do
    post api_v1_transactions_url, params: { transaction: { name: "Test" } }
    assert_response :unauthorized
  end

  # UPDATE action tests
  test "should update transaction with valid parameters" do
    update_params = {
      transaction: {
        name: "Updated Transaction Name",
        amount: 30.00
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal "Updated Transaction Name", response_data["name"]
  end

  test "should reject update with read-only API key" do
    update_params = {
      transaction: {
        name: "Updated Transaction Name"
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should reject update for non-existent transaction" do
    put api_v1_transaction_url(999999),
        params: { transaction: { name: "Test" } },
        headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should reject update without API key" do
    put api_v1_transaction_url(@transaction), params: { transaction: { name: "Test" } }
    assert_response :unauthorized
  end

  test "should reject update on read-only shared account" do
    shared_owner = users(:family_member)
    shared_account = @family.accounts.create!(
      owner: shared_owner,
      name: "Shared Read Only Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    shared_account.share_with!(@user, permission: "read_only")
    entry = shared_account.entries.create!(
      name: "Read Only Shared Transaction",
      amount: 20,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    put api_v1_transaction_url(entry.transaction),
        params: { transaction: { name: "Blocked Update" } },
        headers: api_headers(@api_key)

    assert_response :forbidden
    assert_equal "Read Only Shared Transaction", entry.reload.name
  end

  test "should allow annotation update on read write shared account without changing financial fields" do
    shared_owner = users(:family_member)
    shared_account = @family.accounts.create!(
      owner: shared_owner,
      name: "Shared Annotation Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    shared_account.share_with!(@user, permission: "read_write")
    entry = shared_account.entries.create!(
      name: "Shared Annotation Transaction",
      amount: 20,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )
    category = @family.categories.create!(
      name: "Shared Annotation Category #{SecureRandom.hex(4)}",
      color: "#4CAF50",
      lucide_icon: "tag"
    )
    merchant = @family.merchants.create!(name: "Shared Annotation Merchant #{SecureRandom.hex(4)}")

    put api_v1_transaction_url(entry.transaction),
        params: {
          transaction: {
            name: "Blocked Name",
            amount: 999,
            date: Date.current - 10.days,
            notes: "Allowed annotation",
            category_id: category.id,
            merchant_id: merchant.id,
            tag_ids: [ Tag.first.id ]
          }
        },
        headers: api_headers(@api_key)

    assert_response :success

    entry.reload
    transaction = entry.transaction.reload
    assert_equal "Shared Annotation Transaction", entry.name
    assert_equal BigDecimal("20"), entry.amount
    assert_equal Date.current, entry.date
    assert_equal "Allowed annotation", entry.notes
    assert_equal category.id, transaction.category_id
    assert_equal merchant.id, transaction.merchant_id
    assert_equal [ Tag.first.id ], transaction.tag_ids
  end

  test "should preserve tags when tag_ids not provided in update" do
    # Set up transaction with existing tags
    original_tags = [ Tag.first, Tag.second ]
    @transaction.tags = original_tags
    @transaction.save!

    # Update only the name, without providing tag_ids
    update_params = {
      transaction: {
        name: "Updated Name Only"
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    @transaction.reload
    assert_equal "Updated Name Only", @transaction.entry.name
    # Tags should be preserved since tag_ids was not in the request
    assert_equal original_tags.map(&:id).sort, @transaction.tag_ids.sort
  end

  test "should clear tags when empty tag_ids explicitly provided in update" do
    # Set up transaction with existing tags
    @transaction.tags = [ Tag.first, Tag.second ]
    @transaction.save!

    # Explicitly provide empty tag_ids to clear tags
    update_params = {
      transaction: {
        name: "Updated Name",
        tag_ids: []
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    @transaction.reload
    # Tags should be cleared since tag_ids was explicitly provided as empty
    assert_empty @transaction.tags
  end

  test "should update tags when tag_ids explicitly provided in update" do
    # Set up transaction with one tag
    @transaction.tags = [ Tag.first ]
    @transaction.save!

    new_tags = [ Tag.second ]

    update_params = {
      transaction: {
        tag_ids: new_tags.map(&:id)
      }
    }

    put api_v1_transaction_url(@transaction),
        params: update_params,
        headers: api_headers(@api_key)
    assert_response :success

    @transaction.reload
    assert_equal new_tags.map(&:id), @transaction.tag_ids
  end

  test "should update tags through dedicated tags endpoint" do
    @transaction.tags = [ Tag.first ]
    @transaction.save!

    patch tags_api_v1_transaction_url(@transaction),
          params: { transaction: { tag_ids: [ Tag.second.id ] } },
          headers: api_headers(@api_key)

    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal [ Tag.second.id ], @transaction.reload.tag_ids
    assert_equal [ Tag.second.id ], response_data["tags"].map { |tag| tag["id"] }
  end

  test "should clear tags through dedicated tags endpoint" do
    @transaction.tags = [ Tag.first, Tag.second ]
    @transaction.save!

    patch tags_api_v1_transaction_url(@transaction),
          params: { transaction: { tag_ids: [] } },
          headers: api_headers(@api_key)

    assert_response :success
    assert_empty @transaction.reload.tags
    assert_empty JSON.parse(response.body)["tags"]
  end

  test "should allow read write shared account user to update tags through dedicated endpoint" do
    shared_owner = users(:family_member)
    shared_account = @family.accounts.create!(
      owner: shared_owner,
      name: "Shared Annotatable Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    shared_account.share_with!(@user, permission: "read_write")
    entry = shared_account.entries.create!(
      name: "Shared Annotatable Transaction",
      amount: 20,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    patch tags_api_v1_transaction_url(entry.transaction),
          params: { transaction: { tag_ids: [ Tag.first.id ] } },
          headers: api_headers(@api_key)

    assert_response :success
    assert_equal [ Tag.first.id ], entry.transaction.reload.tag_ids
  end

  test "should reject read only shared account user updating tags through dedicated endpoint" do
    shared_owner = users(:family_member)
    shared_account = @family.accounts.create!(
      owner: shared_owner,
      name: "Shared Read Only Tag Checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    shared_account.share_with!(@user, permission: "read_only")
    entry = shared_account.entries.create!(
      name: "Shared Read Only Tag Transaction",
      amount: 20,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    patch tags_api_v1_transaction_url(entry.transaction),
          params: { transaction: { tag_ids: [ Tag.first.id ] } },
          headers: api_headers(@api_key)

    assert_response :forbidden
    assert_empty entry.transaction.reload.tags
  end

  test "should ignore tags outside current family through dedicated tags endpoint" do
    other_family = Family.create!(
      name: "Other API Family",
      currency: "USD",
      locale: "en",
      date_format: "%m-%d-%Y"
    )
    other_tag = other_family.tags.create!(name: "Other Family", color: "#123456")

    patch tags_api_v1_transaction_url(@transaction),
          params: { transaction: { tag_ids: [ Tag.first.id, other_tag.id ] } },
          headers: api_headers(@api_key)

    assert_response :success
    assert_equal [ Tag.first.id ], @transaction.reload.tag_ids
  end

  # BULK UPDATE action tests
  test "should bulk update transactions" do
    entry_one = create_test_transaction_entry(name: "Bulk update one")
    entry_two = create_test_transaction_entry(name: "Bulk update two")

    patch bulk_update_api_v1_transactions_url,
          params: {
            bulk_update: {
              entry_ids: [ entry_one.id, entry_two.id ],
              name: "Mobile bulk update",
              notes: "Updated from mobile"
            }
          },
          headers: api_headers(@api_key)

    assert_response :success

    response_data = JSON.parse(response.body)
    assert_equal 2, response_data["requested_count"]
    assert_equal 2, response_data["matched_count"]
    assert_equal 2, response_data["updated_count"]
    assert_equal 0, response_data["skipped_count"]
    assert_equal "Mobile bulk update", entry_one.reload.name
    assert_equal "Mobile bulk update", entry_two.reload.name
    assert_equal "Updated from mobile", entry_one.notes
    assert_equal "Updated from mobile", entry_two.notes
  end

  test "should preserve tags when tag_ids not provided in bulk update" do
    entry = create_test_transaction_entry(name: "Bulk preserve tags")
    entry.transaction.tags = [ Tag.first ]
    entry.transaction.save!

    patch bulk_update_api_v1_transactions_url,
          params: {
            bulk_update: {
              entry_ids: [ entry.id ],
              name: "Bulk renamed"
            }
          },
          headers: api_headers(@api_key)

    assert_response :success
    assert_equal [ Tag.first.id ], entry.transaction.reload.tag_ids
  end

  test "should clear tags when empty tag_ids explicitly provided in bulk update" do
    entry = create_test_transaction_entry(name: "Bulk clear tags")
    entry.transaction.tags = [ Tag.first, Tag.second ]
    entry.transaction.save!

    patch bulk_update_api_v1_transactions_url,
          params: {
            bulk_update: {
              entry_ids: [ entry.id ],
              tag_ids: []
            }
          },
          headers: api_headers(@api_key)

    assert_response :success
    assert_empty entry.transaction.reload.tags
  end

  test "should reject bulk update with read-only API key" do
    entry = create_test_transaction_entry(name: "Read only bulk update")

    patch bulk_update_api_v1_transactions_url,
          params: { bulk_update: { entry_ids: [ entry.id ], name: "Blocked" } },
          headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should reject bulk update without entry ids" do
    patch bulk_update_api_v1_transactions_url,
          params: { bulk_update: { name: "Missing ids" } },
          headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "entry_ids is required", response_data["message"]
  end

  # DESTROY action tests
  test "should destroy transaction" do
    entry_to_delete = @account.entries.create!(
      name: "Transaction to Delete",
      amount: 10.00,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )
    transaction_to_delete = entry_to_delete.transaction

    assert_difference("@account.entries.count", -1) do
      delete api_v1_transaction_url(transaction_to_delete), headers: api_headers(@api_key)
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert response_data.key?("message")
  end

  test "should reject destroy with read-only API key" do
    delete api_v1_transaction_url(@transaction), headers: api_headers(@read_only_api_key)
    assert_response :forbidden
  end

  test "should reject destroy for non-existent transaction" do
    delete api_v1_transaction_url(999999), headers: api_headers(@api_key)
    assert_response :not_found
  end

  test "should reject destroy without API key" do
    delete api_v1_transaction_url(@transaction)
    assert_response :unauthorized
  end

  # BULK DELETE action tests
  test "should bulk delete transactions" do
    entry_one = create_test_transaction_entry(name: "Bulk delete one")
    entry_two = create_test_transaction_entry(name: "Bulk delete two")

    assert_difference("Entry.count", -2) do
      delete bulk_delete_api_v1_transactions_url,
             params: { bulk_delete: { entry_ids: [ entry_one.id, entry_two.id ] } },
             headers: api_headers(@api_key)
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal 2, response_data["requested_count"]
    assert_equal 2, response_data["deleted_count"]
    assert_equal 0, response_data["skipped_count"]
  end

  test "should skip split children in bulk delete" do
    parent_entry = create_test_transaction_entry(name: "Bulk split parent", amount: 100)
    child_entry = @account.entries.create!(
      name: "Bulk split child",
      amount: 40,
      currency: "USD",
      date: parent_entry.date,
      parent_entry: parent_entry,
      entryable: Transaction.new
    )

    assert_no_difference("Entry.count") do
      delete bulk_delete_api_v1_transactions_url,
             params: { bulk_delete: { entry_ids: [ child_entry.id ] } },
             headers: api_headers(@api_key)
    end

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal 1, response_data["requested_count"]
    assert_equal 0, response_data["deleted_count"]
    assert_equal 1, response_data["skipped_count"]
    assert Entry.exists?(child_entry.id)
  end

  test "should reject bulk delete with read-only API key" do
    entry = create_test_transaction_entry(name: "Read only bulk delete")

    delete bulk_delete_api_v1_transactions_url,
           params: { bulk_delete: { entry_ids: [ entry.id ] } },
           headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should reject bulk delete without entry ids" do
    delete bulk_delete_api_v1_transactions_url,
           params: { bulk_delete: { entry_ids: [] } },
           headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "entry_ids is required", response_data["message"]
  end

  # TRANSACTION ROW ACTION tests
  test "should list duplicate candidates for pending transaction" do
    pending_entry = create_test_transaction_entry(name: "Pending duplicate", amount: 25.00)
    posted_entry = create_test_transaction_entry(name: "Posted duplicate", amount: 25.00, date: Date.current - 1.day)
    pending_entry.transaction.update!(extra: { "plaid" => { "pending" => true } })

    get duplicate_candidates_api_v1_transaction_url(pending_entry.transaction),
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    candidate_ids = response_data["duplicate_candidates"].map { |candidate| candidate["entry_id"] }
    assert_includes candidate_ids, posted_entry.id
    assert response_data["pagination"].key?("has_more")
  end

  test "should reject duplicate candidates for posted transaction" do
    entry = create_test_transaction_entry(name: "Posted only")

    get duplicate_candidates_api_v1_transaction_url(entry.transaction),
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "Transaction is not pending", response_data["message"]
  end

  test "should merge pending duplicate with posted entry" do
    pending_entry = create_test_transaction_entry(name: "Pending merge", amount: 25.00)
    posted_entry = create_test_transaction_entry(name: "Posted merge", amount: 25.00, date: Date.current - 1.day)
    pending_entry.transaction.update!(extra: { "plaid" => { "pending" => true } })

    assert_difference("Entry.count", -1) do
      post merge_duplicate_api_v1_transaction_url(pending_entry.transaction),
           params: { duplicate: { posted_entry_id: posted_entry.id } },
           headers: api_headers(@api_key)
    end

    assert_response :success
    assert_not Entry.exists?(pending_entry.id)
    assert Entry.exists?(posted_entry.id)
  end

  test "should reject duplicate merge with invalid posted entry" do
    pending_entry = create_test_transaction_entry(name: "Invalid pending merge", amount: 25.00)
    pending_entry.transaction.update!(extra: { "plaid" => { "pending" => true } })

    post merge_duplicate_api_v1_transaction_url(pending_entry.transaction),
         params: { duplicate: { posted_entry_id: SecureRandom.uuid } },
         headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "posted_entry_id is invalid", response_data["message"]
  end

  test "should dismiss duplicate suggestion" do
    pending_entry = create_test_transaction_entry(name: "Dismiss duplicate", amount: 25.00)
    posted_entry = create_test_transaction_entry(name: "Dismiss posted", amount: 25.00, date: Date.current - 1.day)
    pending_entry.transaction.update!(
      extra: {
        "potential_posted_match" => {
          "entry_id" => posted_entry.id,
          "reason" => "manual_match",
          "confidence" => "high"
        }
      }
    )

    post dismiss_duplicate_api_v1_transaction_url(pending_entry.transaction),
         headers: api_headers(@api_key)

    assert_response :success
    assert_equal true, pending_entry.transaction.reload.extra.dig("potential_posted_match", "dismissed")
  end

  test "should mark transaction as recurring" do
    entry = create_test_transaction_entry(name: "Monthly recurring", amount: 25.00, date: Date.current - 1.month)

    assert_difference("RecurringTransaction.count", 1) do
      post mark_as_recurring_api_v1_transaction_url(entry.transaction),
           headers: api_headers(@api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal entry.account.id, response_data["account"]["id"]
    assert_equal "Monthly recurring", response_data["name"]
  end

  test "should return conflict when recurring transaction already exists" do
    entry = create_test_transaction_entry(name: "Existing recurring", amount: 25.00, date: Date.current - 1.month)
    RecurringTransaction.create_from_transaction(entry.transaction)

    assert_no_difference("RecurringTransaction.count") do
      post mark_as_recurring_api_v1_transaction_url(entry.transaction),
           headers: api_headers(@api_key)
    end

    assert_response :conflict
    response_data = JSON.parse(response.body)
    assert_equal "Recurring transaction already exists", response_data["message"]
  end

  test "should convert investment transaction to trade" do
    investment_account = accounts(:investment)
    security = Security.create!(ticker: "CONV", name: "Conversion Security", country_code: "US")
    entry = investment_account.entries.create!(
      name: "Brokerage buy",
      amount: 250.00,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    assert_difference("Trade.count", 1) do
      assert_difference("Entry.count", 1) do
        post convert_to_trade_api_v1_transaction_url(entry.transaction),
             params: {
               trade_conversion: {
                 security_id: security.id,
                 qty: 5,
                 investment_activity_label: "Buy"
               }
             },
             headers: api_headers(@api_key)
      end
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    trade = Trade.find(response_data["id"])

    assert_equal security.id, trade.security_id
    assert_equal BigDecimal("5"), trade.qty
    assert_equal BigDecimal("50"), trade.price
    assert_equal "Buy", trade.investment_activity_label
    assert_equal true, entry.reload.excluded?
    assert trade.entry.user_modified?
  end

  test "should reject convert to trade for non-investment transaction" do
    entry = create_test_transaction_entry(name: "Not an investment", amount: 250.00)
    security = Security.create!(ticker: "NOINV", name: "No Investment Security", country_code: "US")

    assert_no_difference("Trade.count") do
      post convert_to_trade_api_v1_transaction_url(entry.transaction),
           params: { trade_conversion: { security_id: security.id, qty: 5 } },
           headers: api_headers(@api_key)
    end

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "Transaction must belong to an investment account", response_data["message"]
  end

  test "should reject convert to trade with read-only API key" do
    investment_account = accounts(:investment)
    security = Security.create!(ticker: "READONLY", name: "Read Only Security", country_code: "US")
    entry = investment_account.entries.create!(
      name: "Read only conversion",
      amount: 250.00,
      currency: "USD",
      date: Date.current,
      entryable: Transaction.new
    )

    post convert_to_trade_api_v1_transaction_url(entry.transaction),
         params: { trade_conversion: { security_id: security.id, qty: 5 } },
         headers: api_headers(@read_only_api_key)

    assert_response :forbidden
  end

  test "should unlock transaction for sync" do
    entry = create_test_transaction_entry(name: "Locked transaction")
    entry.mark_user_modified!
    entry.lock_saved_attributes!
    entry.transaction.lock_attr!(:tag_ids)

    post unlock_api_v1_transaction_url(entry.transaction),
         headers: api_headers(@api_key)

    assert_response :success
    entry.reload
    assert_not entry.user_modified?
    assert_empty entry.locked_attributes
    assert_empty entry.transaction.locked_attributes
  end

  # JSON structure tests
  test "transaction JSON should have expected structure" do
    get api_v1_transaction_url(@transaction), headers: api_headers(@api_key)
    assert_response :success

    transaction_data = JSON.parse(response.body)

    # Basic fields
    assert transaction_data.key?("id")
    assert transaction_data.key?("entry_id")
    assert transaction_data.key?("date")
    assert transaction_data.key?("amount")
    assert transaction_data.key?("currency")
    assert transaction_data.key?("name")
    assert transaction_data.key?("classification")
    assert transaction_data.key?("pending")
    assert transaction_data.key?("protection")
    assert transaction_data.key?("duplicate_suggestion")
    assert transaction_data.key?("created_at")
    assert transaction_data.key?("updated_at")

    # Account information
    assert transaction_data.key?("account")
    assert transaction_data["account"].key?("id")
    assert transaction_data["account"].key?("name")
    assert transaction_data["account"].key?("account_type")

    # Optional fields should be present (even if nil)
    assert transaction_data.key?("category")
    assert transaction_data.key?("merchant")
    assert transaction_data.key?("tags")
    assert transaction_data.key?("transfer")
    assert transaction_data.key?("notes")
  end

  test "transactions with transfers should include transfer information" do
    transfer = create_transfer_between_accounts

    get api_v1_transaction_url(transfer.inflow_transaction), headers: api_headers(@api_key)
    assert_response :success

    transaction_data = JSON.parse(response.body)
    assert_not_nil transaction_data["transfer"]
    assert transaction_data["transfer"].key?("id")
    assert transaction_data["transfer"].key?("amount")
    assert transaction_data["transfer"].key?("currency")
    assert transaction_data["transfer"].key?("other_account")
  end

  test "index renders transfer rows without per-transfer transaction lookups" do
    transfer = create_transfer_between_accounts

    queries = capture_sql_queries do
      get api_v1_transactions_url,
          params: { per_page: 100 },
          headers: api_headers(@api_key)
    end

    assert_response :success

    response_data = JSON.parse(response.body)
    transfer_transaction_ids = [ transfer.inflow_transaction_id, transfer.outflow_transaction_id ]
    transfer_rows = response_data["transactions"].select { |transaction| transfer_transaction_ids.include?(transaction["id"]) }

    assert_equal 2, transfer_rows.size
    assert transfer_rows.all? { |transaction| transaction["transfer"].present? }
    assert_empty queries.grep(/SELECT "transactions"\.\* FROM "transactions" WHERE "transactions"\."id" =/)
    assert_empty queries.grep(/SELECT "entries"\.\* FROM "entries" WHERE "entries"\."id" =/)
    assert_empty queries.grep(/SELECT "accounts"\.\* FROM "accounts" WHERE "accounts"\."id" =/)
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end

    def create_transfer_between_accounts
      from_account = @family.accounts.create!(
        name: "Transfer From Account",
        balance: 1000,
        currency: "USD",
        accountable: Depository.new
      )

      to_account = @family.accounts.create!(
        name: "Transfer To Account",
        balance: 0,
        currency: "USD",
        accountable: Depository.new
      )

      Transfer::Creator.new(
        family: @family,
        source_account_id: from_account.id,
        destination_account_id: to_account.id,
        date: Date.current,
        amount: 100
      ).create
    end

    def capture_sql_queries
      queries = []
      callback = lambda do |_name, _started, _finished, _unique_id, payload|
        next if payload[:cached]
        next if %w[SCHEMA TRANSACTION].include?(payload[:name])

        queries << payload[:sql].squish
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        yield
      end

      queries
    end

    # Validates agent-friendly numeric fields: type, sign invariants
    def assert_amount_cents_fields(txn_json)
      assert txn_json.key?("amount_cents"), "Expected amount_cents field"
      assert txn_json.key?("signed_amount_cents"), "Expected signed_amount_cents field"
      assert txn_json.key?("converted_amount_cents"), "Expected converted_amount_cents field"
      assert txn_json.key?("converted_currency"), "Expected converted_currency field"
      assert_kind_of Integer, txn_json["amount_cents"]
      assert_kind_of Integer, txn_json["signed_amount_cents"]
      assert_kind_of Integer, txn_json["converted_amount_cents"]
      assert_kind_of String, txn_json["converted_currency"]
      assert_operator txn_json["amount_cents"], :>=, 0, "amount_cents must be non-negative"
      assert_equal txn_json["amount_cents"].abs, txn_json["signed_amount_cents"].abs,
                   "Absolute values of amount_cents and signed_amount_cents must match"
      if txn_json["classification"] == "income"
        assert_operator txn_json["signed_amount_cents"], :>=, 0,
                        "income transactions should have non-negative signed_amount_cents"
        assert_operator txn_json["converted_amount_cents"], :>=, 0,
                        "income transactions should have non-negative converted_amount_cents"
      else
        assert_operator txn_json["signed_amount_cents"], :<=, 0,
                        "non-income transactions should have non-positive signed_amount_cents"
        assert_operator txn_json["converted_amount_cents"], :<=, 0,
                        "non-income transactions should have non-positive converted_amount_cents"
      end
    end

    def create_disabled_account_transaction(name:, date: Date.current)
      create_account_transaction(status: "disabled", name: name, date: date)
    end

    def create_test_transaction_entry(name:, date: Date.current, amount: 10.00)
      @account.entries.create!(
        name: name,
        amount: amount,
        currency: "USD",
        date: date,
        entryable: Transaction.new
      )
    end

    def create_account_transaction(status:, name:, date: Date.current)
      account = @family.accounts.create!(
        name: "#{status.titleize} Checking #{SecureRandom.hex(4)}",
        balance: 0,
        currency: "USD",
        status: status,
        accountable: Depository.new
      )

      entry = account.entries.create!(
        name: name,
        amount: 12.34,
        currency: "USD",
        date: date,
        entryable: Transaction.new
      )

      entry.transaction
    end
end
