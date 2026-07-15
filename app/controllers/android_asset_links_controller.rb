class AndroidAssetLinksController < ApplicationController
  DEFAULT_PACKAGE_NAME = "com.mujhtech.northledger"
  FINGERPRINT_PATTERN = /\A(?:[0-9A-F]{2}:){31}[0-9A-F]{2}\z/

  skip_authentication
  skip_before_action :verify_authenticity_token
  skip_before_action :require_onboarding_and_upgrade, raise: false
  skip_before_action :set_default_chat, raise: false
  skip_before_action :detect_os, raise: false

  def show
    expires_in 1.hour, public: true
    render json: asset_links
  end

  private

    def asset_links
      return [] if certificate_fingerprints.empty?

      [
        {
          relation: [ "delegate_permission/common.get_login_creds" ],
          target: {
            namespace: "android_app",
            package_name: ENV.fetch("ANDROID_APP_PACKAGE_NAME", DEFAULT_PACKAGE_NAME).presence || DEFAULT_PACKAGE_NAME,
            sha256_cert_fingerprints: certificate_fingerprints
          }
        }
      ]
    end

    def certificate_fingerprints
      @certificate_fingerprints ||= ENV.fetch("ANDROID_APP_SHA256_CERT_FINGERPRINTS", "")
        .split(/[\n,]/)
        .filter_map { |value| normalize_fingerprint(value) }
        .uniq
    end

    def normalize_fingerprint(value)
      compact = value.strip.upcase.delete(":")
      return unless compact.match?(/\A[0-9A-F]{64}\z/)

      normalized = compact.scan(/.{2}/).join(":")
      normalized if normalized.match?(FINGERPRINT_PATTERN)
    end
end
