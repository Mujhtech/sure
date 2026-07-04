# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountStatementsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @account = accounts(:depository)
    @user.api_keys.active.destroy_all
    @read_api_key = ApiKey.create!(
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
  end

  test "lists visible account statements" do
    statement = create_statement!("visible.csv", account: @account)

    get api_v1_account_statements_url, headers: api_headers(@read_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_includes response_data["account_statements"].map { |item| item["id"] }, statement.id
    assert response_data.key?("pagination")
  end

  test "shows account statement" do
    statement = create_statement!("show.csv", account: @account)

    get api_v1_account_statement_url(statement), headers: api_headers(@read_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    assert_equal statement.id, response_data["id"]
    assert_equal @account.id, response_data.dig("account", "id")
    assert response_data.key?("download_path")
  end

  test "uploads account statement to an account" do
    assert_difference("AccountStatement.count", 1) do
      post api_v1_account_statements_url,
           params: {
             account_statement: {
               account_id: @account.id,
               files: [ uploaded_file(filename: "api_statement.csv", content_type: "text/csv") ]
             }
           },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :created
    response_data = JSON.parse(response.body)
    assert_equal 1, response_data["account_statements"].size
    assert_equal @account.id, response_data.dig("account_statements", 0, "account", "id")
  end

  test "rejects duplicate upload without creating statement" do
    create_statement!("duplicate.csv", account: @account, content: "date,amount\n2024-01-01,1\n")

    assert_no_difference("AccountStatement.count") do
      post api_v1_account_statements_url,
           params: {
             account_statement: {
               account_id: @account.id,
               files: [ uploaded_file(filename: "duplicate-again.csv", content_type: "text/csv", content: "date,amount\n2024-01-01,1\n") ]
             }
           },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "updates statement metadata and account link" do
    statement = create_statement!("metadata.csv", account: nil)

    patch api_v1_account_statement_url(statement),
          params: {
            account_statement: {
              account_id: @account.id,
              institution_name_hint: "Mobile Bank",
              period_start_on: "2024-01-01",
              period_end_on: "2024-01-31"
            }
          },
          headers: api_headers(@read_write_api_key)

    assert_response :success
    statement.reload
    assert_equal @account.id, statement.account_id
    assert_equal "Mobile Bank", statement.institution_name_hint
  end

  test "links statement to suggested account" do
    statement = create_statement!("suggested.csv", account: nil)
    statement.update!(suggested_account: @account, match_confidence: 0.9)

    patch link_api_v1_account_statement_url(statement), headers: api_headers(@read_write_api_key)

    assert_response :success
    assert_equal @account.id, statement.reload.account_id
    assert statement.linked?
  end

  test "unlinks statement" do
    statement = create_statement!("unlink.csv", account: @account)

    patch unlink_api_v1_account_statement_url(statement), headers: api_headers(@read_write_api_key)

    assert_response :success
    assert_nil statement.reload.account_id
    assert statement.unmatched?
  end

  test "rejects statement match" do
    statement = create_statement!("reject.csv", account: nil)
    statement.update!(suggested_account: @account, match_confidence: 0.9)

    patch reject_api_v1_account_statement_url(statement), headers: api_headers(@read_write_api_key)

    assert_response :success
    assert statement.reload.rejected?
    assert_nil statement.suggested_account_id
  end

  test "deletes statement" do
    statement = create_statement!("delete.csv", account: @account)

    assert_difference("AccountStatement.count", -1) do
      delete api_v1_account_statement_url(statement), headers: api_headers(@read_write_api_key)
    end

    assert_response :success
  end

  test "downloads statement original file" do
    statement = create_statement!("download.csv", account: @account)

    get download_api_v1_account_statement_url(statement), headers: api_headers(@read_api_key)

    assert_response :redirect
  end

  test "non manager cannot list statement vault" do
    guest = family_guest
    guest.api_keys.active.destroy_all
    key = ApiKey.create!(
      user: guest,
      name: "Guest Read Key",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "guest_read_#{SecureRandom.hex(8)}"
    )

    get api_v1_account_statements_url, headers: api_headers(key)

    assert_response :forbidden
  end

  private

    def create_statement!(filename, account:, content: "date,amount\n2024-01-01,1\n")
      AccountStatement.create_from_upload!(
        family: @user.family,
        account: account,
        file: uploaded_file(filename: filename, content_type: "text/csv", content: content)
      )
    end
end
