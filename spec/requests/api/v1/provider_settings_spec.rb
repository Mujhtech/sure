# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "Api::V1::ProviderSettings", type: :request do
  let(:family) do
    Family.create!(
      name: "API Provider Settings Family",
      currency: "USD",
      locale: "en",
      date_format: "%m-%d-%Y"
    )
  end

  let(:user) do
    family.users.create!(
      email: "api-provider-settings@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: "admin",
      onboarded_at: Time.current
    )
  end

  let(:member) do
    family.users.create!(
      email: "api-provider-settings-member@example.com",
      password: "password123",
      password_confirmation: "password123",
      role: "member",
      onboarded_at: Time.current
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "Provider Settings Docs Key",
      key: key,
      scopes: %w[read_write],
      source: "mobile"
    )
  end

  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "Provider Settings Read Key",
      key: key,
      scopes: %w[read],
      source: "mobile"
    )
  end

  let(:member_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: member,
      name: "Provider Settings Member Key",
      key: key,
      scopes: %w[read_write],
      source: "mobile"
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  before do
    Provider::Factory.ensure_adapters_loaded
  end

  path "/api/v1/provider_settings" do
    get "Show provider settings" do
      tags "Provider Settings"
      description "Returns registered global provider configuration fields for admin mobile settings screens. Secret values are represented only by configured/source metadata and are never returned."
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "provider settings returned" do
        schema "$ref" => "#/components/schemas/ProviderSettingsResponse"

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end

    patch "Update provider settings" do
      tags "Provider Settings"
      description "Updates registered global provider configuration fields. Secret fields ignore blank values and the redacted placeholder, so clients can submit existing forms without resending secrets."
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          setting: {
            type: :object,
            properties: {
              plaid_client_id: { type: :string },
              plaid_secret: { type: :string },
              plaid_environment: { type: :string, enum: %w[sandbox development production] },
              plaid_eu_client_id: { type: :string },
              plaid_eu_secret: { type: :string },
              plaid_eu_environment: { type: :string, enum: %w[sandbox development production] }
            }
          }
        }
      }

      let(:body) do
        {
          setting: {
            plaid_client_id: "docs-plaid-client",
            plaid_secret: "********",
            plaid_environment: "sandbox"
          }
        }
      end

      response "200", "provider settings updated" do
        schema "$ref" => "#/components/schemas/ProviderSettingsMutationResponse"
        run_test!
      end

      response "401", "unauthorized" do
        let(:'X-Api-Key') { nil }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "insufficient scope" do
        let(:'X-Api-Key') { read_only_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "403", "family admin required" do
        let(:'X-Api-Key') { member_api_key.plain_key }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end

      response "400", "missing settings payload" do
        let(:body) { {} }
        schema "$ref" => "#/components/schemas/ErrorResponse"
        run_test!
      end
    end
  end
end
