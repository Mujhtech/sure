# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "API V1 Savings Challenge", type: :request do
  let(:family) do
    Family.create!(name: "Challenge Family", currency: "USD", locale: "en", date_format: "%m-%d-%Y")
  end

  let(:user) do
    family.users.create!(
      email: "api-savings-challenge@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end

  let(:account) do
    family.accounts.create!(
      owner: user,
      name: "Savings",
      accountable: Depository.new,
      balance: 2_500,
      currency: "USD"
    )
  end

  let(:read_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user:, name: "Challenge Read Key", key:, display_key: key, scopes: %w[read], source: "web")
  end

  let(:write_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user:, name: "Challenge Write Key", key:, display_key: key, scopes: %w[read_write], source: "mobile")
  end

  let(:"X-Api-Key") { read_key.plain_key }

  path "/api/v1/savings_challenge" do
    get "Retrieve the 30-Day Savings Challenge" do
      tags "Savings Challenge"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "challenge retrieved" do
        schema "$ref" => "#/components/schemas/SavingsChallengeResponse"

        run_test!
      end
    end

    post "Join the 30-Day Savings Challenge" do
      tags "Savings Challenge"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        required: %w[challenge],
        properties: {
          challenge: {
            type: :object,
            required: %w[target_amount account_id],
            properties: {
              target_amount: { type: :number, exclusiveMinimum: 0 },
              account_id: { type: :string, format: :uuid }
            }
          }
        }
      }

      let(:"X-Api-Key") { write_key.plain_key }
      let(:body) { { challenge: { target_amount: 500, account_id: account.id } } }

      response "201", "challenge joined" do
        schema "$ref" => "#/components/schemas/SavingsChallengeResponse"

        run_test!
      end
    end
  end
end
