# frozen_string_literal: true

module Api
  module V1
    class MerchantsController < BaseController
      before_action -> { authorize_scope!(:read) }, only: [ :index, :show ]
      before_action -> { authorize_scope!(:write) }, only: [ :create, :update, :destroy, :merge, :enhance ]
      before_action :set_merchant, only: [ :update, :destroy ]

      def index
        family = current_resource_owner.family
        user = current_resource_owner

        family_merchant_ids = family.merchants.select(:id)
        accessible_account_ids = family.accounts.accessible_by(user).select(:id)
        provider_merchant_ids = Transaction.joins(:entry)
          .where(entries: { account_id: accessible_account_ids })
          .where.not(merchant_id: nil)
          .select(:merchant_id)

        @merchants = Merchant
          .where(id: family_merchant_ids)
          .or(Merchant.where(id: provider_merchant_ids, type: "ProviderMerchant"))
          .distinct
          .alphabetically

        render json: @merchants.map { |m| merchant_json(m) }
      rescue StandardError => e
        Rails.logger.error("API Merchants Error: #{e.message}")
        render json: { error: "Failed to fetch merchants" }, status: :internal_server_error
      end

      def show
        family = current_resource_owner.family
        user = current_resource_owner

        @merchant = family.merchants.find_by(id: params[:id]) ||
                    Merchant.joins(transactions: :entry)
                            .where(entries: { account_id: family.accounts.accessible_by(user).select(:id) })
                            .distinct
                            .find_by(id: params[:id])

        if @merchant
          render json: merchant_json(@merchant)
        else
          render json: { error: "Merchant not found" }, status: :not_found
        end
      rescue StandardError => e
        Rails.logger.error("API Merchant Show Error: #{e.message}")
        render json: { error: "Failed to fetch merchant" }, status: :internal_server_error
      end

      def create
        if params[:merchant].present?
          @merchant = current_resource_owner.family.merchants.new(merchant_params)

          if @merchant.save
            return render json: merchant_json(@merchant), status: :created
          end

          return render json: {
            error: "validation_failed",
            message: "Merchant could not be created",
            errors: @merchant.errors.full_messages
          }, status: :unprocessable_entity
        end

        family = current_resource_owner.family

        unless params[:file].present?
          return render json: { error: "missing_file", message: "Please provide a merchant payload or CSV file." },
                        status: :unprocessable_entity
        end

        file = params[:file]

        if file.size > Import::MAX_CSV_SIZE
          return render json: {
            error: "file_too_large",
            message: "File is too large. Maximum size is #{Import::MAX_CSV_SIZE / 1.megabyte}MB."
          }, status: :unprocessable_entity
        end

        unless Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
          return render json: {
            error: "invalid_file_type",
            message: "Invalid file type. Please upload a CSV file."
          }, status: :unprocessable_entity
        end

        csv = Import.parse_csv_str(file.read)

        name_header = normalized_header(csv.headers, "name")
        unless name_header
          return render json: {
            error: "missing_column",
            message: "CSV must include a 'name' column."
          }, status: :unprocessable_entity
        end

        color_header = normalized_header(csv.headers, "color")
        website_url_header = normalized_header(csv.headers, "website_url", "website url", "website")

        imported = []
        skipped = []

        csv.each do |row|
          name = row[name_header].to_s.strip
          next if name.blank?

          merchant = family.merchants.find_or_initialize_by(name: name)

          if merchant.persisted?
            skipped << { name: name, reason: "already_exists" }
            next
          end

          merchant.color = row[color_header].to_s.strip.presence if color_header
          merchant.website_url = row[website_url_header].to_s.strip.presence if website_url_header

          if merchant.save
            imported << merchant
          else
            skipped << { name: name, errors: merchant.errors.full_messages }
          end
        end

        render json: {
          imported: imported.count,
          skipped: skipped.count,
          merchants: imported.map { |m| merchant_json(m) }
        }, status: :created
      rescue CSV::MalformedCSVError => e
        render json: { error: "invalid_csv", message: "CSV could not be parsed: #{e.message}" },
               status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error("API Merchants Import Error: #{e.message}")
        render json: { error: "internal_server_error", message: "An unexpected error occurred" },
               status: :internal_server_error
      end

      def update
        attrs = merchant_params

        if @merchant.is_a?(ProviderMerchant)
          if attrs[:name].present? && attrs[:name] != @merchant.name
            @merchant = @merchant.convert_to_family_merchant_for(current_resource_owner.family, attrs)
          else
            @merchant.update!(attrs.slice(:website_url))
            @merchant.generate_logo_url_from_website!
          end
        else
          @merchant.update!(attrs)
        end

        render json: merchant_json(@merchant)
      rescue ActiveRecord::RecordInvalid => e
        render json: {
          error: "validation_failed",
          message: "Merchant could not be updated",
          errors: e.record.errors.full_messages
        }, status: :unprocessable_entity
      end

      def destroy
        if @merchant.is_a?(ProviderMerchant)
          @merchant.unlink_from_family(current_resource_owner.family)
        else
          @merchant.destroy!
        end

        render json: { message: "Merchant deleted successfully" }, status: :ok
      end

      def merge
        merge_params = merchant_merge_params
        target_id = merge_params[:target_id].to_s
        source_ids = Array(merge_params[:source_ids]).map(&:to_s).reject(&:blank?).uniq

        if target_id.present? && source_ids.include?(target_id)
          render_validation_error("Target merchant cannot also be a source merchant")
          return
        end

        target = writable_merchants.find_by(id: target_id)
        unless target
          render_validation_error("Target merchant not found")
          return
        end

        unless source_ids.any?
          render_validation_error("No source merchants selected")
          return
        end

        sources = writable_merchants.where(id: source_ids).to_a
        if sources.size != source_ids.size
          render_validation_error("One or more source merchants were not found")
          return
        end

        merger = Merchant::Merger.new(
          family: current_resource_owner.family,
          target_merchant: target,
          source_merchants: sources
        )

        unless merger.merge!
          render_validation_error("No source merchants selected")
          return
        end

        render json: {
          message: "Merchants merged successfully",
          merged_count: merger.merged_count,
          merchant: merchant_json(target.reload)
        }, status: :ok
      rescue Merchant::Merger::UnauthorizedMerchantError => e
        render_validation_error(e.message)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotDestroyed => e
        render_validation_error(record_error_message(e))
      end

      def enhance
        family = current_resource_owner.family
        cache_key = "enhance_provider_merchants:#{family.id}"
        already_running = !Rails.cache.write(cache_key, true, expires_in: 10.minutes, unless_exist: true)

        if already_running
          render json: {
            error: "enhance_already_running",
            message: "Merchant enhancement is already running"
          }, status: :unprocessable_entity
          return
        end

        EnhanceProviderMerchantsJob.perform_later(family)

        render json: {
          message: "Merchant enhancement started",
          enhanceable_count: enhanceable_provider_merchants_count
        }, status: :accepted
      end

      private

        def set_merchant
          unless valid_uuid?(params[:id])
            render json: { error: "not_found", message: "Merchant not found" }, status: :not_found
            return
          end

          @merchant = writable_merchants.find_by(id: params[:id])
          return if @merchant

          render json: { error: "not_found", message: "Merchant not found" }, status: :not_found
        end

        def writable_merchants
          family = current_resource_owner.family
          family_merchant_ids = family.merchants.select(:id)
          provider_merchant_ids = family.assigned_merchants_for(current_resource_owner).where(type: "ProviderMerchant").select(:id)

          Merchant.where(id: family_merchant_ids).or(Merchant.where(id: provider_merchant_ids))
        end

        def merchant_params
          params.require(:merchant).permit(:name, :color, :website_url)
        end

        def merchant_merge_params
          params.permit(:target_id, source_ids: [])
        end

        def merchant_json(merchant)
          {
            id: merchant.id,
            name: merchant.name,
            type: merchant.type,
            color: merchant.respond_to?(:color) ? merchant.color : nil,
            logo_url: merchant.respond_to?(:logo_url) ? merchant.logo_url : nil,
            website_url: merchant.respond_to?(:website_url) ? merchant.website_url : nil,
            created_at: merchant.created_at,
            updated_at: merchant.updated_at
          }
        end

        def normalized_header(headers, *candidates)
          normalized_map = headers.to_h { |h| [ normalize(h), h ] }
          candidates.each do |candidate|
            header = normalized_map[normalize(candidate)]
            return header if header.present?
          end
          nil
        end

        def normalize(str)
          str.to_s.strip.downcase.gsub(/\*/, "").gsub(/[\s_-]+/, "_")
        end

        def enhanceable_provider_merchants_count
          current_resource_owner.family
            .assigned_merchants_for(current_resource_owner)
            .where(type: "ProviderMerchant", website_url: [ nil, "" ])
            .count
        end

        def record_error_message(error)
          record = error.respond_to?(:record) ? error.record : nil
          record&.errors&.full_messages&.to_sentence.presence || error.message
        end
    end
  end
end
