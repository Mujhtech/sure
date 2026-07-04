# frozen_string_literal: true

module Api
  module V1
    # API v1 endpoint for tags
    # Provides full CRUD operations for family tags
    #
    # @example List all tags
    #   GET /api/v1/tags
    #
    # @example Create a new tag
    #   POST /api/v1/tags
    #   { "tag": { "name": "WhiteHouse", "color": "#3b82f6" } }
    #
    class TagsController < BaseController
      before_action -> { authorize_scope!(:read) }, only: %i[index show]
      before_action -> { authorize_scope!(:read_write) }, only: %i[create update destroy replace_and_destroy destroy_all]
      before_action :set_tag, only: %i[show update destroy replace_and_destroy]

      # List all tags belonging to the family
      #
      # @return [Array<Hash>] JSON array of tag objects sorted alphabetically
      def index
        family = current_resource_owner.family
        @tags = family.tags.alphabetically

        render json: @tags.map { |t| tag_json(t) }
      rescue StandardError => e
        Rails.logger.error("API Tags Error: #{e.message}")
        render json: { error: "Failed to fetch tags" }, status: :internal_server_error
      end

      # Get a specific tag by ID
      #
      # @param id [String] The tag ID
      # @return [Hash] JSON tag object
      def show
        render json: tag_json(@tag)
      rescue StandardError => e
        Rails.logger.error("API Tag Show Error: #{e.message}")
        render json: { error: "Failed to fetch tag" }, status: :internal_server_error
      end

      # Create a new tag for the family
      #
      # @param name [String] Tag name (required)
      # @param color [String] Hex color code (optional, auto-assigned if not provided)
      # @return [Hash] JSON tag object with status 201
      def create
        family = current_resource_owner.family
        @tag = family.tags.new(tag_params)

        # Assign random color if not provided
        @tag.color ||= Tag::COLORS.sample

        if @tag.save
          render json: tag_json(@tag), status: :created
        else
          render json: { error: @tag.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error("API Tag Create Error: #{e.message}")
        render json: { error: "Failed to create tag" }, status: :internal_server_error
      end

      # Update an existing tag
      #
      # @param id [String] The tag ID
      # @param name [String] New tag name (optional)
      # @param color [String] New hex color code (optional)
      # @return [Hash] JSON tag object
      def update
        if @tag.update(tag_params)
          render json: tag_json(@tag)
        else
          render json: { error: @tag.errors.full_messages.join(", ") }, status: :unprocessable_entity
        end
      rescue StandardError => e
        Rails.logger.error("API Tag Update Error: #{e.message}")
        render json: { error: "Failed to update tag" }, status: :internal_server_error
      end

      # Delete a tag
      #
      # @param id [String] The tag ID
      # @return [nil] Empty response with status 204
      def destroy
        @tag.destroy!
        head :no_content
      rescue StandardError => e
        Rails.logger.error("API Tag Destroy Error: #{e.message}")
        render json: { error: "Failed to delete tag" }, status: :internal_server_error
      end

      # Replace a tag's assignments with another family tag, then delete the source tag.
      #
      # @param id [String] The source tag ID
      # @param replacement_tag_id [String] The target tag ID
      # @return [Hash] JSON response with replacement details
      def replace_and_destroy
        replacement = replacement_tag
        return if performed?

        replaced_taggings_count = @tag.taggings.count
        source_tag_id = @tag.id
        source_tag_name = @tag.name

        @tag.replace_and_destroy!(replacement)

        render json: {
          message: "Tag replaced and deleted successfully",
          replaced_taggings_count: replaced_taggings_count,
          deleted_tag: {
            id: source_tag_id,
            name: source_tag_name
          },
          replacement_tag: tag_json(replacement)
        }, status: :ok
      rescue ActiveRecord::RecordInvalid => e
        render json: {
          error: "validation_failed",
          message: e.message,
          errors: [ e.message ]
        }, status: :unprocessable_entity
      rescue StandardError => e
        Rails.logger.error("API Tag Replace And Destroy Error: #{e.message}")
        render json: { error: "Failed to replace and delete tag" }, status: :internal_server_error
      end

      # Delete all tags for the family
      #
      # @return [Hash] JSON response with the remaining tag count
      def destroy_all
        current_resource_owner.family.tags.destroy_all

        render json: {
          message: "Tags deleted successfully",
          tags_count: current_resource_owner.family.tags.count
        }, status: :ok
      rescue StandardError => e
        Rails.logger.error("API Tags Destroy All Error: #{e.message}")
        render json: { error: "Failed to delete tags" }, status: :internal_server_error
      end

      private

        # Find and set the tag from params
        #
        # @raise [ActiveRecord::RecordNotFound] if tag not found
        # @return [Tag] The found tag
        def set_tag
          family = current_resource_owner.family
          @tag = family.tags.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: { error: "Tag not found" }, status: :not_found
        end

        # Strong parameters for tag creation/update
        #
        # @return [ActionController::Parameters] Permitted parameters
        def tag_params
          params.require(:tag).permit(:name, :color)
        end

        def replacement_tag
          replacement_tag_id = params[:replacement_tag_id].presence || params.dig(:tag, :replacement_tag_id).presence

          unless replacement_tag_id
            render json: {
              error: "validation_failed",
              message: "replacement_tag_id is required",
              errors: [ "replacement_tag_id is required" ]
            }, status: :unprocessable_entity
            return
          end

          unless valid_uuid?(replacement_tag_id)
            render json: {
              error: "validation_failed",
              message: "replacement_tag_id is invalid",
              errors: [ "replacement_tag_id is invalid" ]
            }, status: :unprocessable_entity
            return
          end

          replacement = current_resource_owner.family.tags.find_by(id: replacement_tag_id)
          unless replacement
            render json: {
              error: "validation_failed",
              message: "Replacement tag not found",
              errors: [ "Replacement tag not found" ]
            }, status: :unprocessable_entity
            return
          end

          replacement
        end

        # Serialize a tag to JSON format
        #
        # @param tag [Tag] The tag to serialize
        # @return [Hash] JSON-serializable hash
        def tag_json(tag)
          {
            id: tag.id,
            name: tag.name,
            color: tag.color,
            created_at: tag.created_at,
            updated_at: tag.updated_at
          }
        end
    end
  end
end
