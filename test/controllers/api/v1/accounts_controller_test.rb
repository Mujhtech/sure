# frozen_string_literal: true

require "test_helper"

class Api::V1::AccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin) # dylan_family user
    @other_family_user = users(:family_member)
    @other_family_user.update!(family: families(:empty))

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

    @other_family_user.api_keys.active.destroy_all
    @other_family_api_key = ApiKey.create!(
      user: @other_family_user,
      name: "Other Family Read Key",
      scopes: [ "read" ],
      source: "web",
      display_key: "other_family_read_#{SecureRandom.hex(8)}"
    )
  end

  test "should require authentication" do
    get "/api/v1/accounts"
    assert_response :unauthorized

    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should require read_accounts scope" do
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Key",
      scopes: [],
      source: "web",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to exercise the runtime insufficient-scope guard.
    api_key_without_read.save!(validate: false)

    get "/api/v1/accounts", params: {}, headers: api_headers(api_key_without_read)

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should return user's family accounts successfully" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have accounts array
    assert response_body.key?("accounts")
    assert response_body["accounts"].is_a?(Array)

    # Should have pagination metadata
    assert response_body.key?("pagination")
    assert response_body["pagination"].key?("page")
    assert response_body["pagination"].key?("per_page")
    assert response_body["pagination"].key?("total_count")
    assert response_body["pagination"].key?("total_pages")

    # All accounts should belong to user's family
    response_body["accounts"].each do |account|
      # We'll validate this by checking the user's family has these accounts
      family_account_names = @user.family.accounts.pluck(:name)
      assert_includes family_account_names, account["name"]
    end
  end

  test "should only return active accounts" do
    # Make one account inactive
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should not include the inactive account
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_not_includes account_names, inactive_account.name
  end

  test "should include disabled accounts when requested" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts", params: { include_disabled: true }, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    account = response_body["accounts"].find { |account_data| account_data["id"] == inactive_account.id }
    assert_not_nil account
    assert_equal "disabled", account["status"]
  end

  test "should show active account" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal account.id, response_body["id"]
    assert_equal account.status, response_body["status"]
    assert_equal account.balance_money.format, response_body["balance"]
    assert_equal money_cents(account.balance_money), response_body["balance_cents"]
    assert_equal account.cash_balance_money.format, response_body["cash_balance"]
    assert_equal money_cents(account.cash_balance_money), response_body["cash_balance_cents"]
    assert_nullable_equal account.subtype, response_body["subtype"]
    assert response_body.key?("institution_name")
    assert response_body.key?("institution_domain")
    assert_nullable_equal account.institution_name, response_body["institution_name"]
    assert_nullable_equal account.institution_domain, response_body["institution_domain"]
    assert_equal account.created_at.iso8601, response_body["created_at"]
    assert_equal account.updated_at.iso8601, response_body["updated_at"]
    assert response_body.key?("exclude_from_reports")
    assert response_body.key?("default")
    assert response_body.key?("transaction_default_eligible")
    assert response_body.key?("syncing")
  end

  test "should return 404 for unknown account on show" do
    get "/api/v1/accounts/#{SecureRandom.uuid}", headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
  end

  test "should return 404 for malformed account id on show" do
    get "/api/v1/accounts/not-a-uuid", headers: api_headers(@api_key)

    assert_response :not_found
    response_body = JSON.parse(response.body)
    assert_equal "not_found", response_body["error"]
    assert_equal "Account not found", response_body["message"]
  end

  test "should require authentication on show" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}"

    assert_response :unauthorized
    response_body = JSON.parse(response.body)
    assert_equal "unauthorized", response_body["error"]
  end

  test "should require read scope on show" do
    account = accounts(:depository)
    api_key_without_read = ApiKey.new(
      user: @user,
      name: "No Read Show Key",
      scopes: [],
      source: "web",
      display_key: "no_read_show_#{SecureRandom.hex(8)}"
    )
    # Valid persisted API keys can only be read/read_write; this intentionally
    # bypasses validations to exercise the runtime insufficient-scope guard.
    api_key_without_read.save!(validate: false)

    get "/api/v1/accounts/#{account.id}", headers: api_headers(api_key_without_read)

    assert_response :forbidden
    response_body = JSON.parse(response.body)
    assert_equal "insufficient_scope", response_body["error"]
  ensure
    api_key_without_read&.destroy
  end

  test "should return account series" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}/series",
        params: { period: "last_30_days" },
        headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal account.id, response_body.dig("account", "id")
    assert_equal "balance", response_body["view"]
    assert response_body.key?("period")
    assert response_body.key?("series")
    assert response_body["series"].key?("values")
    assert response_body["series"]["values"].is_a?(Array)
  end

  test "should reject invalid account series view" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}/series",
        params: { view: "market_value" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
    assert_match "view", response_body["message"]
  end

  test "should reject invalid account series date" do
    account = accounts(:depository)

    get "/api/v1/accounts/#{account.id}/series",
        params: { start_date: "06/01/2026" },
        headers: api_headers(@api_key)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
    assert_equal "start_date must be an ISO 8601 date", response_body["message"]
  end

  test "should hide disabled account by default on show" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts/#{inactive_account.id}", headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "should show disabled account when requested" do
    inactive_account = accounts(:depository)
    inactive_account.disable!

    get "/api/v1/accounts/#{inactive_account.id}",
        params: { include_disabled: true },
        headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal inactive_account.id, response_body["id"]
    assert_equal "disabled", response_body["status"]
  end

  test "should expose subtype across account types" do
    expected_subtypes = {
      accounts(:depository) => "checking",
      accounts(:credit_card) => "credit_card",
      accounts(:investment) => "brokerage",
      accounts(:loan) => "mortgage",
      accounts(:property) => "single_family_home",
      accounts(:vehicle) => nil,
      accounts(:crypto) => "exchange",
      accounts(:other_asset) => "collectible",
      accounts(:other_liability) => "personal_debt"
    }

    expected_subtypes.each do |account, subtype|
      account.accountable.update!(subtype: subtype) if account.accountable.respond_to?(:subtype=)
    end

    expected_subtypes.each do |account, subtype|
      get "/api/v1/accounts/#{account.id}", headers: api_headers(@api_key)

      assert_response :success
      assert_equal subtype, JSON.parse(response.body)["subtype"]
    end
  end

  test "should expose accountable details across account types" do
    accounts(:depository).accountable.update!(subtype: "hsa")
    accounts(:investment).accountable.update!(subtype: "brokerage")
    accounts(:crypto).accountable.update!(subtype: "exchange", tax_treatment: "tax_deferred")
    accounts(:loan).accountable.update!(subtype: "mortgage", rate_type: "fixed", interest_rate: 3.5, term_months: 360, initial_balance: 500000)
    accounts(:vehicle).accountable.update!(make: "Honda", model: "Accord", year: 2024, mileage_value: 12000, mileage_unit: "mi")
    accounts(:other_asset).accountable.update!(subtype: "collectible")
    accounts(:other_liability).accountable.update!(subtype: "personal_debt")

    credit_card = accounts(:credit_card).accountable
    get "/api/v1/accounts/#{accounts(:credit_card).id}", headers: api_headers(@api_key)

    assert_response :success
    accountable = JSON.parse(response.body)["accountable"]
    assert_equal credit_card.id, accountable["id"]
    assert_equal "CreditCard", accountable["type"]
    assert_equal "credit_card", accountable["key"]
    assert_equal "credit_card", accountable["subtype"]
    assert_equal credit_card.available_credit.to_s("F"), accountable["available_credit"]
    assert_equal credit_card.minimum_payment.to_s("F"), accountable["minimum_payment"]
    assert_equal credit_card.apr.to_s("F"), accountable["apr"]
    assert_equal credit_card.annual_fee.to_s("F"), accountable["annual_fee"]
    assert_equal credit_card.expiration_date.iso8601, accountable["expiration_date"]

    get "/api/v1/accounts/#{accounts(:investment).id}", headers: api_headers(@api_key)
    assert_response :success
    accountable = JSON.parse(response.body)["accountable"]
    assert_equal "Investment", accountable["type"]
    assert_equal "brokerage", accountable["subtype"]
    assert_equal "taxable", accountable["tax_treatment"]

    get "/api/v1/accounts/#{accounts(:crypto).id}", headers: api_headers(@api_key)
    assert_response :success
    accountable = JSON.parse(response.body)["accountable"]
    assert_equal "Crypto", accountable["type"]
    assert_equal "exchange", accountable["subtype"]
    assert_equal "tax_deferred", accountable["tax_treatment"]

    get "/api/v1/accounts/#{accounts(:loan).id}", headers: api_headers(@api_key)
    assert_response :success
    accountable = JSON.parse(response.body)["accountable"]
    assert_equal "Loan", accountable["type"]
    assert_equal "mortgage", accountable["subtype"]
    assert_equal "fixed", accountable["rate_type"]
    assert_equal "3.5", accountable["interest_rate"]
    assert_equal 360, accountable["term_months"]
    assert_equal "500000.0", accountable["initial_balance"]

    get "/api/v1/accounts/#{accounts(:property).id}", headers: api_headers(@api_key)
    assert_response :success
    accountable = JSON.parse(response.body)["accountable"]
    assert_equal "Property", accountable["type"]
    assert_equal 2002, accountable["year_built"]
    assert_equal 1000, accountable["area_value"]
    assert_equal "sqft", accountable["area_unit"]
    assert_equal "123 Main Street", accountable.dig("address", "line1")
    assert_equal "Los Angeles", accountable.dig("address", "locality")

    get "/api/v1/accounts/#{accounts(:vehicle).id}", headers: api_headers(@api_key)
    assert_response :success
    accountable = JSON.parse(response.body)["accountable"]
    assert_equal "Vehicle", accountable["type"]
    assert_equal "Honda", accountable["make"]
    assert_equal "Accord", accountable["model"]
    assert_equal 2024, accountable["year"]
    assert_equal 12000, accountable["mileage_value"]
    assert_equal "mi", accountable["mileage_unit"]
  end

  test "should not return other family's accounts" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@other_family_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should return empty array since other family has no accounts in fixtures
    assert_equal [], response_body["accounts"]
    assert_equal 0, response_body["pagination"]["total_count"]
  end

  test "should create manual account" do
    Account.any_instance.stubs(:sync_later)

    assert_difference("@user.family.accounts.count", 1) do
      post api_v1_accounts_url,
           params: {
             account: {
               name: "Mobile Savings",
               balance: 1234.56,
               currency: "USD",
               subtype: "savings",
               accountable_type: "Depository",
               opening_balance_date: "2026-01-01"
             }
           },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "Mobile Savings", response_body["name"]
    assert_equal "depository", response_body["account_type"]
    assert_equal "savings", response_body["subtype"]
    assert_equal false, response_body["linked"]
    assert_equal true, response_body["manual"]
  end

  test "should create property account with address details" do
    Account.any_instance.stubs(:sync_later)

    assert_difference([ "@user.family.accounts.count", "Address.count" ], 1) do
      post api_v1_accounts_url,
           params: {
             account: {
               name: "Mobile Property",
               balance: 425000,
               currency: "USD",
               accountable_type: "Property",
               opening_balance_date: "2026-01-01",
               accountable_attributes: {
                 subtype: "single_family_home",
                 year_built: 2018,
                 area_value: 1800,
                 area_unit: "sqft",
                 address_attributes: {
                   line1: "742 Evergreen Terrace",
                   county: "Sangamon",
                   locality: "Springfield",
                   region: "IL",
                   country: "US",
                   postal_code: "62704"
                 }
               }
             }
           },
           headers: api_headers(@read_write_api_key)
    end

    assert_response :created
    response_body = JSON.parse(response.body)
    assert_equal "property", response_body["account_type"]
    assert_equal "Property", response_body.dig("accountable", "type")
    assert_equal "single_family_home", response_body.dig("accountable", "subtype")
    assert_equal 2018, response_body.dig("accountable", "year_built")
    assert_equal 1800, response_body.dig("accountable", "area_value")
    assert_equal "742 Evergreen Terrace", response_body.dig("accountable", "address", "line1")
    assert_equal "Sangamon", response_body.dig("accountable", "address", "county")
    assert_equal "Springfield", response_body.dig("accountable", "address", "locality")
  end

  test "should reject account create with invalid type" do
    post api_v1_accounts_url,
         params: {
           account: {
             name: "Bad Account",
             balance: 10,
             currency: "USD",
             accountable_type: "UnknownType"
           }
         },
         headers: api_headers(@read_write_api_key)

    assert_response :unprocessable_entity
  end

  test "should update manual account" do
    account = accounts(:depository)

    patch api_v1_account_url(account),
          params: { account: { name: "Renamed Checking", notes: "Updated from mobile", balance: 5100 } },
          headers: api_headers(@read_write_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "Renamed Checking", response_body["name"]
    assert_equal account.reload.balance_money.format, response_body["balance"]
    assert_equal "Updated from mobile", account.notes
  end

  test "should update property account with address details" do
    account = accounts(:property)
    property = account.accountable
    address = property.address

    patch api_v1_account_url(account),
          params: {
            account: {
              accountable_attributes: {
                id: property.id,
                subtype: "townhouse",
                year_built: 1999,
                area_value: 1450,
                area_unit: "sqm",
                address_attributes: {
                  id: address.id,
                  line1: "456 Oak Avenue",
                  line2: "Unit 8",
                  county: "King",
                  locality: "Seattle",
                  region: "WA",
                  country: "US",
                  postal_code: "98101"
                }
              }
            }
          },
          headers: api_headers(@read_write_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal "townhouse", response_body.dig("accountable", "subtype")
    assert_equal 1999, response_body.dig("accountable", "year_built")
    assert_equal 1450, response_body.dig("accountable", "area_value")
    assert_equal "sqm", response_body.dig("accountable", "area_unit")
    assert_equal "456 Oak Avenue", response_body.dig("accountable", "address", "line1")
    assert_equal "Unit 8", response_body.dig("accountable", "address", "line2")
    assert_equal "King", response_body.dig("accountable", "address", "county")
    assert_equal "Seattle", property.reload.address.locality
  end

  test "should schedule manual account deletion" do
    account = @user.family.accounts.create!(
      owner: @user,
      name: "Disposable Account",
      balance: 25,
      currency: "USD",
      accountable: OtherAsset.new
    )

    assert_no_difference("@user.family.accounts.count") do
      delete api_v1_account_url(account), headers: api_headers(@read_write_api_key)
    end

    assert_response :accepted
    assert_equal "pending_deletion", account.reload.status
  end

  test "should reject linked account deletion" do
    account = accounts(:connected)

    delete api_v1_account_url(account), headers: api_headers(@read_write_api_key)

    assert_response :unprocessable_entity
    assert_not_equal "pending_deletion", account.reload.status
  end

  test "should unlink linked account" do
    account = accounts(:connected)
    assert account.linked?

    delete "/api/v1/accounts/#{account.id}/unlink", headers: api_headers(@read_write_api_key)

    assert_response :success
    response_body = JSON.parse(response.body)
    assert_equal account.id, response_body["id"]
    assert_equal false, response_body["linked"]
    assert_equal true, response_body["manual"]
    assert_nil account.reload.plaid_account_id
    assert_not account.linked?
  end

  test "should reject unlink for manual account" do
    account = accounts(:depository)
    assert_not account.linked?

    delete "/api/v1/accounts/#{account.id}/unlink", headers: api_headers(@read_write_api_key)

    assert_response :unprocessable_entity
    response_body = JSON.parse(response.body)
    assert_equal "validation_failed", response_body["error"]
    assert_equal "Account is not linked to a provider", response_body["message"]
  end

  test "should reject unlink with read-only key" do
    account = accounts(:connected)

    delete "/api/v1/accounts/#{account.id}/unlink", headers: api_headers(@api_key)

    assert_response :forbidden
    assert account.reload.linked?
  end

  test "should toggle account active status" do
    account = accounts(:depository)

    patch toggle_active_api_v1_account_url(account), headers: api_headers(@read_write_api_key)

    assert_response :success
    assert_equal "disabled", JSON.parse(response.body)["status"]

    patch toggle_active_api_v1_account_url(account), headers: api_headers(@read_write_api_key)

    assert_response :success
    assert_equal "active", JSON.parse(response.body)["status"]
  end

  test "should toggle exclude from reports" do
    account = accounts(:depository)

    patch toggle_exclude_from_reports_api_v1_account_url(account), headers: api_headers(@read_write_api_key)

    assert_response :success
    assert_equal true, JSON.parse(response.body)["exclude_from_reports"]
    assert_equal true, account.reload.exclude_from_reports?
  end

  test "should set and remove default account" do
    account = accounts(:depository)

    patch set_default_api_v1_account_url(account), headers: api_headers(@read_write_api_key)

    assert_response :success
    assert_equal true, JSON.parse(response.body)["default"]
    assert_equal account.id, @user.reload.default_account_id

    patch remove_default_api_v1_account_url(account), headers: api_headers(@read_write_api_key)

    assert_response :success
    assert_nil @user.reload.default_account_id
  end

  test "should reject account mutation with read-only key" do
    account = accounts(:depository)

    patch toggle_exclude_from_reports_api_v1_account_url(account), headers: api_headers(@api_key)

    assert_response :forbidden
  end

  test "should handle pagination parameters" do
    # Test with pagination params
    get "/api/v1/accounts", params: { page: 1, per_page: 2 }, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should respect per_page limit
    assert response_body["accounts"].length <= 2
    assert_equal 1, response_body["pagination"]["page"]
    assert_equal 2, response_body["pagination"]["per_page"]
  end

  test "should return proper account data structure" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have at least one account from fixtures
    assert response_body["accounts"].length > 0

    account = response_body["accounts"].first

    # Check required fields are present
    required_fields = %w[id name balance balance_cents cash_balance cash_balance_cents currency classification account_type]
    required_fields.each do |field|
      assert account.key?(field), "Account should have #{field} field"
    end

    # Check data types
    assert account["id"].is_a?(String), "ID should be string (UUID)"
    assert account["name"].is_a?(String), "Name should be string"
    assert account["balance"].is_a?(String), "Balance should be string (money)"
    assert account["balance_cents"].is_a?(Integer), "Balance cents should be integer"
    assert account["cash_balance_cents"].is_a?(Integer), "Cash balance cents should be integer"
    assert account["currency"].is_a?(String), "Currency should be string"
    assert %w[asset liability].include?(account["classification"]), "Classification should be asset or liability"
  end

  test "should handle invalid pagination parameters gracefully" do
    # Test with invalid page number
    get "/api/v1/accounts", params: { page: -1, per_page: "invalid" }, headers: api_headers(@api_key)

    # Should still return success with default pagination
    assert_response :success
    response_body = JSON.parse(response.body)

    # Should have pagination info (with defaults applied)
    assert response_body.key?("pagination")
    assert response_body["pagination"]["page"] >= 1
    assert response_body["pagination"]["per_page"] > 0
  end

  test "should sort accounts alphabetically" do
    get "/api/v1/accounts", params: {}, headers: api_headers(@api_key)

    assert_response :success
    response_body = JSON.parse(response.body)

    # Should be sorted alphabetically by name
    account_names = response_body["accounts"].map { |a| a["name"] }
    assert_equal account_names.sort, account_names
  end

  private

    def api_headers(api_key)
      { "X-Api-Key" => api_key.plain_key }
    end

    def money_cents(money)
      (money.amount * money.currency.minor_unit_conversion).round(0).to_i
    end

    def assert_nullable_equal(expected, actual)
      expected.nil? ? assert_nil(actual) : assert_equal(expected, actual)
    end
end
