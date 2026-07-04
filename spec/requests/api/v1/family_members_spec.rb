# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "API V1 Family Members", type: :request do
  let(:user) { users(:family_admin) }
  let(:family) { user.family }
  let(:member) { users(:family_member) }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "Family Members Docs Key",
      key: key,
      scopes: %w[read_write],
      source: "web"
    )
  end
  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "Family Members Read Docs Key",
      key: key,
      scopes: %w[read],
      source: "mobile"
    )
  end
  let(:'X-Api-Key') { api_key.plain_key }

  path "/api/v1/family_members" do
    get "List family members" do
      tags "Family Members"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "family members listed" do
        schema "$ref" => "#/components/schemas/FamilyMembersResponse"

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        before do
          family.invitations.create!(
            email: "pending-member-docs@example.com",
            role: "member",
            inviter: user
          )
        end

        run_test!
      end
    end
  end

  path "/api/v1/family_members/{id}" do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    delete "Remove family member" do
      tags "Family Members"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      let(:id) { member.id }

      response "200", "family member removed" do
        schema "$ref" => "#/components/schemas/GenericMessageResponse"

        run_test!
      end

      response "403", "forbidden" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:user) { users(:family_member) }
        let(:id) { users(:family_admin).id }

        run_test!
      end

      response "404", "family member not found" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end
end
