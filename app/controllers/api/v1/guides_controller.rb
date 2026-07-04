# frozen_string_literal: true

class Api::V1::GuidesController < Api::V1::BaseController
  GUIDE_PATH = Rails.root.join("docs/onboarding/guide.md")

  before_action :ensure_read_scope

  def show
    markdown = File.read(GUIDE_PATH)

    render_json({
      guide: {
        slug: "onboarding",
        title: title_from(markdown),
        format: "markdown",
        markdown: markdown,
        byte_size: File.size(GUIDE_PATH),
        updated_at: File.mtime(GUIDE_PATH).iso8601
      }
    })
  rescue Errno::ENOENT
    render_json({
      error: "not_found",
      message: "Guide not found"
    }, status: :not_found)
  end

  private

    def title_from(markdown)
      markdown.each_line do |line|
        title = line.delete_prefix("#").strip if line.start_with?("# ")
        return title if title.present?
      end

      "Guide"
    end
end
