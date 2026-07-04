# frozen_string_literal: true

class Api::V1::AppInfoController < Api::V1::BaseController
  FEEDBACK_LINKS = {
    feature_requests: "https://github.com/we-promise/sure/discussions/categories/feature-requests",
    bug_reports: "https://github.com/we-promise/sure/issues/new?assignees=&labels=bug&template=bug_report.md&title=",
    community: "https://discord.gg/36ZGBsxYEK"
  }.freeze
  RELEASES_URL = "https://github.com/we-promise/sure/releases"

  skip_before_action :authenticate_request!
  skip_before_action :check_api_key_rate_limit
  skip_before_action :log_api_access

  def show
    render json: {
      app: app_payload,
      legal: legal_payload,
      support: support_payload,
      links: links_payload
    }
  end

  def changelog
    render json: { release: release_payload(latest_release_notes) }
  end

  def feedback
    render json: { support: support_payload }
  end

  private

    def app_payload
      {
        name: Rails.configuration.x.product_name,
        mode: Rails.application.config.app_mode.to_s,
        self_hosted: Rails.application.config.app_mode.self_hosted?
      }
    end

    def legal_payload
      {
        privacy: legal_link(
          title: I18n.t("pages.privacy.title"),
          configured_url: ENV["LEGAL_PRIVACY_URL"].presence,
          fallback_url: privacy_url,
          placeholder: I18n.t("pages.privacy.placeholder")
        ),
        terms: legal_link(
          title: I18n.t("pages.terms.title"),
          configured_url: ENV["LEGAL_TERMS_URL"].presence,
          fallback_url: terms_url,
          placeholder: I18n.t("pages.terms.placeholder")
        )
      }
    end

    def legal_link(title:, configured_url:, fallback_url:, placeholder:)
      {
        title: title,
        url: configured_url || fallback_url,
        external: configured_url.present?,
        placeholder: placeholder
      }
    end

    def support_payload
      {
        changelog_url: RELEASES_URL,
        feature_requests_url: FEEDBACK_LINKS.fetch(:feature_requests),
        bug_reports_url: FEEDBACK_LINKS.fetch(:bug_reports),
        community_url: FEEDBACK_LINKS.fetch(:community)
      }
    end

    def links_payload
      {
        changelog: changelog_api_v1_app_info_path,
        feedback: feedback_api_v1_app_info_path
      }
    end

    def latest_release_notes
      Provider::Registry.get_provider(:github)&.fetch_latest_release_notes
    end

    def release_payload(release_notes)
      release_notes ||= fallback_release_notes

      {
        name: release_notes[:name],
        username: release_notes[:username],
        author_url: release_notes[:username].present? ? "https://github.com/#{release_notes[:username]}" : nil,
        avatar_url: release_notes[:avatar],
        published_at: timestamp_payload(release_notes[:published_at]),
        body_html: release_notes[:body] || I18n.t("pages.release_notes_unavailable.body_html"),
        source_url: RELEASES_URL
      }
    end

    def fallback_release_notes
      {
        avatar: "https://github.com/we-promise.png",
        username: "we-promise",
        name: I18n.t("pages.release_notes_unavailable.name"),
        published_at: Date.current,
        body: I18n.t("pages.release_notes_unavailable.body_html")
      }
    end

    def timestamp_payload(value)
      return nil if value.blank?
      return value.iso8601 if value.respond_to?(:iso8601)

      value.to_s
    end
end
