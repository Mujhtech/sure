# frozen_string_literal: true

require "test_helper"

class Api::V1::TransactionCategorizationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @account = accounts(:depository)

    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Categorize Read-Write Key",
      scopes: [ "read_write" ],
      display_key: "categorize_rw_#{SecureRandom.hex(8)}"
    )
    @read_only_api_key = ApiKey.create!(
      user: @user,
      name: "Categorize Read Key",
      scopes: [ "read" ],
      display_key: "categorize_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
    Redis.new.del("api_rate_limit:#{@read_only_api_key.id}")

    @category = @family.categories.create!(
      name: "Mobile Dining #{SecureRandom.hex(4)}",
      color: "#4CAF50",
      lucide_icon: "utensils"
    )
    @merchant = @family.merchants.create!(name: "Mobile Cafe #{SecureRandom.hex(4)}")

    @family.transactions.where(category_id: nil).update_all(category_id: @category.id)

    @entries = 3.times.map do |index|
      @account.entries.create!(
        name: "#{@merchant.name} latte #{index + 1}",
        date: Date.current - index.days,
        amount: 12.34 + index,
        currency: "USD",
        entryable: Transaction.new(merchant: @merchant)
      )
    end
  end

  test "shows next uncategorized transaction group" do
    get "/api/v1/transactions/categorize",
        headers: api_headers(@read_only_api_key)

    assert_response :success

    response_data = response_body
    assert_equal false, response_data["all_done"]
    assert_equal 3, response_data["total_uncategorized"]
    assert_equal @merchant.name, response_data.dig("group", "grouping_key")
    assert_equal "expense", response_data.dig("group", "transaction_type")
    assert_equal @entries.map(&:id).sort, response_data.dig("group", "entry_ids").sort
    assert response_data["categories"].any? { |category| category["id"] == @category.id }
  end

  test "previews rule matches with pagination" do
    get "/api/v1/transactions/categorize/preview_rule",
        params: {
          filter: @merchant.name,
          transaction_type: "expense",
          limit: 1
        },
        headers: api_headers(@read_only_api_key)

    assert_response :success

    response_data = response_body
    assert_equal @merchant.name, response_data["filter"]
    assert_equal "expense", response_data["transaction_type"]
    assert_equal 3, response_data["total_matching"]
    assert_equal 1, response_data["entries"].size
    assert_equal true, response_data.dig("pagination", "has_more")
    assert_nil response_data.dig("entries", 0, "category")
  end

  test "categorizes group and creates rule" do
    post "/api/v1/transactions/categorize",
         params: {
           categorization: {
             entry_ids: @entries.map(&:id),
             all_entry_ids: @entries.map(&:id),
             category_id: @category.id,
             create_rule: true,
             grouping_key: @merchant.name,
             transaction_type: "expense"
           }
         },
         headers: api_headers(@api_key),
         as: :json

    assert_response :success

    response_data = response_body
    assert_equal 3, response_data["requested_count"]
    assert_equal 3, response_data["matched_count"]
    assert_equal 3, response_data["updated_count"]
    assert_equal 0, response_data["skipped_count"]
    assert_equal @category.id, response_data.dig("category", "id")
    assert_equal true, response_data.dig("rule", "requested")
    assert_equal true, response_data.dig("rule", "created")
    assert_equal true, response_data.dig("remaining", "all_done")

    @entries.each do |entry|
      assert_equal @category.id, entry.reload.transaction.category_id
    end

    rule = @family.rules.find(response_data.dig("rule", "id"))
    assert_equal @merchant.name, rule.name
  end

  test "assigns one entry and returns remaining group entries" do
    patch "/api/v1/transactions/categorize/assign_entry",
          params: {
            assignment: {
              entry_id: @entries.first.id,
              all_entry_ids: @entries.map(&:id),
              category_id: @category.id
            }
          },
          headers: api_headers(@api_key),
          as: :json

    assert_response :success

    response_data = response_body
    assert_equal @entries.first.id, response_data["entry_id"]
    assert_equal 1, response_data["updated_count"]
    assert_equal @category.id, response_data.dig("category", "id")
    assert_equal @entries.drop(1).map(&:id).sort, response_data.dig("remaining", "entry_ids").sort
    assert_equal false, response_data.dig("remaining", "all_done")
    assert_equal @category.id, @entries.first.reload.transaction.category_id
  end

  test "categorizes entries on read write shared accounts" do
    shared_entry = create_shared_transaction_entry(permission: "read_write", name: "Shared categorize group")

    post "/api/v1/transactions/categorize",
         params: {
           categorization: {
             entry_ids: [ shared_entry.id ],
             all_entry_ids: [ shared_entry.id ],
             category_id: @category.id
           }
         },
         headers: api_headers(@api_key),
         as: :json

    assert_response :success
    response_data = response_body
    assert_equal 1, response_data["matched_count"]
    assert_equal 1, response_data["updated_count"]
    assert_equal @category.id, shared_entry.reload.transaction.category_id
  end

  test "assigns one entry on a read write shared account" do
    shared_entry = create_shared_transaction_entry(permission: "read_write", name: "Shared assign one")

    patch "/api/v1/transactions/categorize/assign_entry",
          params: {
            assignment: {
              entry_id: shared_entry.id,
              all_entry_ids: [ shared_entry.id ],
              category_id: @category.id
            }
          },
          headers: api_headers(@api_key),
          as: :json

    assert_response :success
    assert_equal @category.id, shared_entry.reload.transaction.category_id
  end

  test "rejects assigning one entry on a read only shared account" do
    shared_entry = create_shared_transaction_entry(permission: "read_only", name: "Shared read only assign")

    patch "/api/v1/transactions/categorize/assign_entry",
          params: {
            assignment: {
              entry_id: shared_entry.id,
              category_id: @category.id
            }
          },
          headers: api_headers(@api_key),
          as: :json

    assert_response :forbidden
    assert_equal "You are not authorized to annotate this transaction", response_body["message"]
    assert_nil shared_entry.reload.transaction.category_id
  end

  test "rejects write actions with read only key" do
    patch "/api/v1/transactions/categorize/assign_entry",
          params: {
            assignment: {
              entry_id: @entries.first.id,
              category_id: @category.id
            }
          },
          headers: api_headers(@read_only_api_key),
          as: :json

    assert_response :forbidden
    assert_nil @entries.first.reload.transaction.category_id
  end

  private

    def response_body
      JSON.parse(response.body)
    end

    def create_shared_transaction_entry(permission:, name:)
      shared_owner = users(:family_member)
      shared_account = @family.accounts.create!(
        owner: shared_owner,
        name: "#{name} Account",
        balance: 0,
        currency: "USD",
        accountable: Depository.new
      )
      shared_account.share_with!(@user, permission: permission)
      shared_account.entries.create!(
        name: name,
        amount: 20,
        currency: "USD",
        date: Date.current,
        entryable: Transaction.new
      )
    end
end
