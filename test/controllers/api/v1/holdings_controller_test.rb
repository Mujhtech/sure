# frozen_string_literal: true

require "test_helper"

class Api::V1::HoldingsControllerTest < ActionDispatch::IntegrationTest
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

    @account = accounts(:investment)
    @holding = holdings(:one)
  end

  test "lists holdings scoped to accessible accounts" do
    other_family_holding = create_other_family_holding

    get api_v1_holdings_url, headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    holding_ids = response_data["holdings"].map { |holding| holding["id"] }

    assert_includes holding_ids, @holding.id
    assert_not_includes holding_ids, other_family_holding.id
  end

  test "shows holding with management flags" do
    get api_v1_holding_url(@holding), headers: api_headers(@api_key)

    assert_response :success
    response_data = JSON.parse(response.body)

    assert_equal @holding.id, response_data["id"]
    assert response_data.key?("cost_basis")
    assert response_data.key?("cost_basis_locked")
    assert response_data.key?("security_locked")
    assert response_data.key?("can_delete")
    assert response_data.key?("can_sync_prices")
    assert response_data["security"].key?("exchange_operating_mic")
    assert response_data["security"].key?("offline")
  end

  test "updates total cost basis as per-share manual basis" do
    @holding.update!(qty: 10, cost_basis: nil, cost_basis_source: nil, cost_basis_locked: false)

    patch api_v1_holding_url(@holding),
          params: { holding: { cost_basis: "100.00" } },
          headers: api_headers(@read_write_api_key)

    assert_response :success
    response_data = JSON.parse(response.body)
    @holding.reload

    assert_equal 10.0, @holding.cost_basis.to_f
    assert_equal "manual", @holding.cost_basis_source
    assert @holding.cost_basis_locked?
    assert_equal "10.0", response_data["cost_basis"]
  end

  test "rejects cost basis update with read-only key" do
    patch api_v1_holding_url(@holding),
          params: { holding: { cost_basis: "100.00" } },
          headers: api_headers(@api_key)

    assert_response :forbidden
  end

  test "rejects invalid cost basis" do
    patch api_v1_holding_url(@holding),
          params: { holding: { cost_basis: "-1" } },
          headers: api_headers(@read_write_api_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "unlock_cost_basis removes lock" do
    @holding.update!(cost_basis: 50.0, cost_basis_source: "manual", cost_basis_locked: true)

    post unlock_cost_basis_api_v1_holding_url(@holding), headers: api_headers(@read_write_api_key)

    assert_response :success
    assert_not @holding.reload.cost_basis_locked?
  end

  test "deletes holding and associated entries" do
    assert_difference -> { Holding.count } => -1,
                      -> { Entry.count } => -1 do
      delete api_v1_holding_url(@holding), headers: api_headers(@read_write_api_key)
    end

    assert_response :success
    assert_empty @account.entries.where(entryable: @account.trades.where(security: @holding.security))
  end

  test "remap_security brings offline target online" do
    msft = securities(:msft)
    msft.update!(offline: true, failed_fetch_count: 3)
    materializer = mock("materializer")
    materializer.expects(:materialize_balances).once
    Balance::Materializer.expects(:new).with(
      @holding.account,
      strategy: :forward,
      security_ids: [ msft.id ]
    ).returns(materializer)

    patch remap_security_api_v1_holding_url(@holding),
          params: { security_id: "MSFT|XNAS" },
          headers: api_headers(@read_write_api_key)

    assert_response :success
    @holding.reload
    msft.reload

    assert_equal msft.id, @holding.security_id
    assert_not msft.offline?
    assert_equal 0, msft.failed_fetch_count
  end

  test "reset_security returns holding to provider security" do
    original_security = securities(:aapl)
    remapped_security = securities(:msft)
    @holding.update!(
      security: remapped_security,
      provider_security: original_security,
      security_locked: true
    )

    post reset_security_api_v1_holding_url(@holding), headers: api_headers(@read_write_api_key)

    assert_response :success
    @holding.reload

    assert_equal original_security.id, @holding.security_id
    assert_not @holding.security_locked?
    assert_nil @holding.provider_security_id
  end

  test "sync_prices rejects offline security" do
    @holding.security.update!(offline: true)

    post sync_prices_api_v1_holding_url(@holding), headers: api_headers(@read_write_api_key)

    assert_response :unprocessable_entity
    assert_equal "validation_failed", JSON.parse(response.body)["error"]
  end

  test "sync_prices materializes balances when provider returns prices" do
    Security.any_instance.expects(:import_provider_prices).with(
      start_date: 31.days.ago.to_date,
      end_date: Date.current,
      clear_cache: true
    ).returns([ 31, nil ])
    Security.any_instance.stubs(:import_provider_details)
    materializer = mock("materializer")
    materializer.expects(:materialize_balances).once
    Balance::Materializer.expects(:new).with(
      @holding.account,
      strategy: :forward,
      security_ids: [ @holding.security_id ]
    ).returns(materializer)

    post sync_prices_api_v1_holding_url(@holding), headers: api_headers(@read_write_api_key)

    assert_response :success
  end

  test "returns not found for another family's holding" do
    other_family_holding = create_other_family_holding

    get api_v1_holding_url(other_family_holding), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "requires authentication" do
    get api_v1_holdings_url

    assert_response :unauthorized
  end

  private

    def create_other_family_holding
      other_user = users(:empty)
      other_account = Account.create!(
        family: other_user.family,
        owner: other_user,
        name: "Other Investment Account",
        balance: 10_000,
        currency: "USD",
        accountable: Investment.create!
      )
      other_security = Security.create!(
        ticker: "OTH#{SecureRandom.hex(2).upcase}",
        name: "Other Security",
        country_code: "US"
      )

      Holding.create!(
        account: other_account,
        security: other_security,
        date: Date.current,
        qty: 5,
        price: 100,
        amount: 500,
        currency: "USD"
      )
    end
end
