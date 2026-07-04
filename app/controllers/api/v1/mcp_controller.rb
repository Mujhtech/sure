# frozen_string_literal: true

class Api::V1::McpController < Api::V1::BaseController
  include OauthBase

  before_action :ensure_read_scope, only: :show
  before_action :ensure_write_scope, only: :revoke_token

  def show
    render_json({
      mcp_url: "#{configured_base_url}/mcp",
      connected_tokens: connected_tokens.map { |token| token_payload(token) }
    })
  end

  def revoke_token
    token = mcp_token_scope.find_by(id: params[:token_id])

    unless token
      render_json({
        error: "not_found",
        message: "MCP token not found"
      }, status: :not_found)
      return
    end

    token.revoke unless token.revoked?

    render_json({
      message: "MCP token revoked",
      token: token_payload(token.reload)
    })
  end

  private

    def connected_tokens
      mcp_token_scope
        .where(revoked_at: nil)
        .includes(:application)
        .order(created_at: :desc)
        .to_a
    end

    def mcp_token_scope
      Doorkeeper::AccessToken
        .where(resource_owner_id: current_resource_owner.id, mobile_device_id: nil)
    end

    def token_payload(token)
      {
        id: token.id,
        scopes: token.scopes.to_a,
        expires_in_seconds: token.expires_in,
        expires_at: token_expires_at(token)&.iso8601,
        expired: token.expired?,
        revoked_at: token.revoked_at&.iso8601,
        created_at: token.created_at.iso8601,
        application: application_payload(token.application)
      }
    end

    def token_expires_at(token)
      return nil if token.expires_in.blank?

      token.created_at + token.expires_in.seconds
    end

    def application_payload(application)
      return nil unless application

      {
        id: application.id,
        name: application.name,
        uid: application.uid,
        redirect_uri: application.redirect_uri,
        confidential: application.confidential?
      }
    end
end
