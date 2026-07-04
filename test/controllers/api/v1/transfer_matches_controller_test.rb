# frozen_string_literal: true

require "test_helper"

class Api::V1::TransferMatchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )
    @read_write_api_key = ApiKey.create!(
      user: @user,
      name: "Test Read Write Key",
      scopes: [ "read_write" ],
      source: "mobile",
      display_key: "test_rw_#{SecureRandom.hex(8)}"
    )

    @source_account = @family.accounts.create!(
      owner: @user,
      name: "Match Checking",
      accountable: Depository.new,
      balance: 500,
      currency: "USD"
    )
    @target_account = @family.accounts.create!(
      owner: @user,
      name: "Match Savings",
      accountable: Depository.new,
      balance: 1000,
      currency: "USD"
    )

    @outflow_entry = create_transaction(@source_account, amount: 75, date: Date.parse("2024-04-10"), name: "Transfer to savings")
    @inflow_entry = create_transaction(@target_account, amount: -75, date: Date.parse("2024-04-11"), name: "Transfer from checking")
  end

  test "lists transfer match candidates and writable target accounts" do
    get "/api/v1/transactions/#{@outflow_entry.transaction.id}/transfer_match",
        headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal @outflow_entry.transaction.id, response_data.dig("transaction", "id")
    assert_includes response_data["target_accounts"].map { |account| account["id"] }, @target_account.id

    candidate = response_data["transfer_match_candidates"].find do |match|
      match.dig("inflow_transaction", "id") == @inflow_entry.transaction.id
    end
    assert_not_nil candidate
    assert_equal @outflow_entry.transaction.id, candidate.dig("outflow_transaction", "id")
    assert_equal 1, candidate["date_diff"]
    assert_equal false, candidate["rejected"]
  end

  test "rejects invalid transfer match date window" do
    get "/api/v1/transactions/#{@outflow_entry.transaction.id}/transfer_match",
        params: { date_window: "soon" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_data = JSON.parse(response.body)
    assert_equal "validation_failed", response_data["error"]
    assert_equal "date_window must be an integer", response_data["message"]
  end

  test "creates transfer match with an existing opposite transaction" do
    assert_difference("Transfer.count", 1) do
      post "/api/v1/transactions/#{@outflow_entry.transaction.id}/transfer_match",
           params: {
             transfer_match: {
               method: "existing",
               matched_entry_id: @inflow_entry.id
             }
           },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "confirmed", response_data["status"]
    assert_equal @inflow_entry.transaction.id, response_data.dig("inflow_transaction", "id")
    assert_equal @outflow_entry.transaction.id, response_data.dig("outflow_transaction", "id")
    assert_equal "funds_movement", @outflow_entry.transaction.reload.kind
    assert_equal "funds_movement", @inflow_entry.transaction.reload.kind
  end

  test "creates transfer match by adding the missing transaction side" do
    assert_difference("Transfer.count", 1) do
      assert_difference("@target_account.entries.count", 1) do
        post "/api/v1/transactions/#{@outflow_entry.transaction.id}/transfer_match",
             params: {
               transfer_match: {
                 method: "new",
                 target_account_id: @target_account.id
               }
             },
             headers: api_headers(@read_write_api_key)
      end
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal "confirmed", response_data["status"]
    assert_equal @outflow_entry.transaction.id, response_data.dig("outflow_transaction", "id")
    assert_equal @target_account.id, response_data.dig("inflow_transaction", "account", "id")

    created_entry = @target_account.entries.where.not(id: @inflow_entry.id).first
    assert_equal(-75, created_entry.amount)
    assert_equal @outflow_entry.date, created_entry.date
    assert created_entry.user_modified?
  end

  test "rejects transfer match mutation with read only key" do
    assert_no_difference("Transfer.count") do
      post "/api/v1/transactions/#{@outflow_entry.transaction.id}/transfer_match",
           params: {
             transfer_match: {
               method: "existing",
               matched_entry_id: @inflow_entry.id
             }
           },
           headers: api_headers(@api_key)
    end

    assert_response :forbidden
  end

  test "returns not found for another family's matched entry" do
    other_family = families(:empty)
    other_account = other_family.accounts.create!(name: "Other Savings", accountable: Depository.new, balance: 0, currency: "USD")
    other_entry = create_transaction(other_account, amount: -75, date: Date.parse("2024-04-11"), name: "Other inflow")

    assert_no_difference("Transfer.count") do
      post "/api/v1/transactions/#{@outflow_entry.transaction.id}/transfer_match",
           params: {
             transfer_match: {
               method: "existing",
               matched_entry_id: other_entry.id
             }
           },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :not_found
  end

  private
    def create_transaction(account, amount:, date:, name:)
      account.entries.create!(
        date: date,
        amount: amount,
        name: name,
        currency: account.currency,
        entryable: Transaction.new(kind: "standard")
      )
    end

    def api_headers(api_key)
      { "X-Api-Key" => api_key.display_key }
    end
end
