# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "API V1 Invitations", type: :request do
  let(:user) { users(:family_admin) }
  let(:family) { user.family }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "Invitations Docs Key",
      key: key,
      scopes: %w[read_write],
      source: "web"
    )
  end
  let(:read_only_api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "Invitations Read Docs Key",
      key: key,
      scopes: %w[read],
      source: "mobile"
    )
  end
  let(:'X-Api-Key') { api_key.plain_key }

  path "/api/v1/invitations" do
    get "List pending invitations" do
      tags "Invitations"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "pending invitations listed" do
        schema "$ref" => "#/components/schemas/InvitationCollection"

        let(:'X-Api-Key') { read_only_api_key.plain_key }

        before do
          family.invitations.create!(
            email: "pending-invitation-docs@example.com",
            role: "member",
            inviter: user
          )
        end

        run_test!
      end
    end

    post "Create invitation" do
      tags "Invitations"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object,
        properties: {
          invitation: {
            type: :object,
            properties: {
              email: { type: :string, format: :email },
              role: { type: :string, enum: %w[guest member admin] }
            },
            required: %w[email role]
          }
        },
        required: %w[invitation]
      }

      let(:body) do
        {
          invitation: {
            email: "new-invite-docs@example.com",
            role: "member"
          }
        }
      end

      response "201", "invitation created" do
        schema "$ref" => "#/components/schemas/Invitation"

        run_test!
      end

      response "403", "forbidden" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:user) { users(:family_member) }

        run_test!
      end

      response "422", "validation failed" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:body) do
          {
            invitation: {
              email: "not-an-email",
              role: "member"
            }
          }
        end

        run_test!
      end
    end
  end

  path "/api/v1/invitations/{id}" do
    parameter name: :id, in: :path, type: :string, format: :uuid, required: true

    let!(:invitation) do
      family.invitations.create!(
        email: "delete-invitation-docs@example.com",
        role: "member",
        inviter: user
      )
    end
    let(:id) { invitation.id }

    delete "Delete invitation" do
      tags "Invitations"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      response "200", "invitation deleted" do
        schema "$ref" => "#/components/schemas/GenericMessageResponse"

        run_test!
      end

      response "404", "invitation not found" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:id) { SecureRandom.uuid }

        run_test!
      end
    end
  end

  path "/api/v1/invitations/accept/{token}" do
    parameter name: :token, in: :path, type: :string, required: true,
              description: "Invitation token from an invitation link."

    let(:invitee) { users(:empty) }
    let(:invitation_email) { invitee.email }
    let(:invitee_api_key) do
      key = ApiKey.generate_secure_key
      ApiKey.create!(
        user: invitee,
        name: "Invitation Accept Docs Key",
        key: key,
        scopes: %w[read_write],
        source: "mobile"
      )
    end
    let!(:accept_invitation) do
      family.invitations.create!(
        email: invitation_email,
        role: "member",
        inviter: user
      )
    end
    let(:token) { accept_invitation.token }

    get "Preview invitation acceptance details" do
      tags "Invitations"
      description "Returns invitation, family, and inviter details for a mobile invitation screen. This endpoint is token-authenticated by the invitation token and does not require an API key."
      produces "application/json"

      response "200", "invitation details returned" do
        schema "$ref" => "#/components/schemas/Invitation"

        run_test!
      end

      response "404", "invitation not found" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:token) { "missing-token" }

        run_test!
      end
    end

    post "Accept invitation as current user" do
      tags "Invitations"
      description "Accepts a pending invitation for the authenticated user when their email matches the invitation email."
      security [ { apiKeyAuth: [] } ]
      produces "application/json"

      let(:'X-Api-Key') { invitee_api_key.plain_key }

      response "200", "invitation accepted" do
        schema "$ref" => "#/components/schemas/Invitation"

        run_test!
      end

      response "422", "current user email does not match invitation" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:invitation_email) { "someone-else-docs@example.com" }

        run_test!
      end

      response "404", "invitation not found" do
        schema "$ref" => "#/components/schemas/ErrorResponse"

        let(:token) { "missing-token" }

        run_test!
      end
    end
  end
end
