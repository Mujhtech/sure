# frozen_string_literal: true

class Api::V1::ImportsController < Api::V1::BaseController
  include Pagy::Backend

  IMPORT_MAPPING_CLASSES = {
    "Import::AccountMapping" => Import::AccountMapping,
    "Import::AccountTypeMapping" => Import::AccountTypeMapping,
    "Import::CategoryMapping" => Import::CategoryMapping,
    "Import::TagMapping" => Import::TagMapping
  }.freeze

  # Ensure proper scope authorization
  before_action :ensure_read_scope, only: [ :index, :show, :rows, :mappings, :qif_category_selection, :preflight, :sample_csv ]
  before_action :ensure_write_scope, only: [ :create, :update, :update_configuration, :apply_template, :update_row, :update_mapping, :update_qif_category_selection, :publish, :revert, :destroy ]
  before_action :set_import_with_rows, only: [ :show ]
  before_action :set_import, only: [ :rows, :mappings, :update, :update_configuration, :apply_template, :update_row, :update_mapping, :qif_category_selection, :update_qif_category_selection, :publish, :revert, :destroy, :sample_csv ]
  before_action :ensure_qif_import, only: [ :qif_category_selection, :update_qif_category_selection ]
  before_action :ensure_import_write_permission, only: [ :update, :update_configuration, :apply_template, :update_row, :update_mapping, :update_qif_category_selection, :publish, :revert, :destroy ]

  def index
    family = current_resource_owner.family
    imports_query = family.imports.ordered

    # Apply filters
    if params[:status].present?
      imports_query = imports_query.where(status: params[:status])
    end

    if params[:type].present?
      imports_query = imports_query.where(type: params[:type])
    end

    # Pagination
    @pagy, @imports = pagy(
      imports_query,
      page: safe_page_param,
      limit: safe_per_page_param
    )

    @per_page = safe_per_page_param

    render :index

  rescue StandardError => e
    Rails.logger.error "ImportsController#index error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
  end

  def show
    render :show
  rescue StandardError => e
    Rails.logger.error "ImportsController#show error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
  end

  def update
    if import_account_id_provided?
      account = import_account_id.present? ? target_import_account : nil
      return if performed?

      if account && !can_manage_import_account?(account)
        render_forbidden("You do not have permission to assign imports to this account")
        return
      end

      assign_import_account!(account)
    end

    @import.reload
    render :show
  rescue ActiveRecord::RecordInvalid => e
    errors = e.record&.errors&.full_messages || [ e.message ]
    render json: {
      error: "validation_failed",
      message: errors.to_sentence.presence || "Import could not be updated",
      errors: errors
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "ImportsController#update error: #{e.message}"
    render json: { error: "internal_server_error", message: "Import could not be updated." }, status: :internal_server_error
  end

  def rows
    @per_page = safe_per_page_param
    @pagy, @rows = pagy(
      @import.rows_ordered,
      page: safe_page_param,
      limit: @per_page
    )
    @rows.each(&:valid?)
    @row_mapping_lookup = @import.mappings.includes(:mappable).index_by { |mapping| [ mapping.type, mapping.key.to_s ] }

    render :rows
  rescue StandardError => e
    Rails.logger.error "ImportsController#rows error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
  end

  def mappings
    render json: { data: import_mappings_payload(@import) }
  rescue StandardError => e
    Rails.logger.error "ImportsController#mappings error: #{e.message}"
    render json: { error: "internal_server_error", message: "Import mappings could not be loaded." }, status: :internal_server_error
  end

  def sample_csv
    template = @import.csv_template if @import.respond_to?(:csv_template)

    unless template&.respond_to?(:to_csv)
      return render json: {
        error: "unsupported_import_type",
        message: "Sample CSV is only available for CSV-backed imports."
      }, status: :unprocessable_entity
    end

    send_data template.to_csv,
      filename: "#{@import.type.underscore.split("_").first}_sample.csv",
      type: "text/csv",
      disposition: "attachment"
  rescue StandardError => e
    Rails.logger.error "ImportsController#sample_csv error: #{e.message}"
    render json: { error: "internal_server_error", message: "Sample CSV could not be generated." }, status: :internal_server_error
  end

  def update_configuration
    if refresh_only_configuration_update?
      @import.update!(rows_to_skip: import_configuration_params[:rows_to_skip].to_i)
    else
      @import.update!(import_configuration_params)
      @import.generate_rows_from_csv
      @import.reload.sync_mappings
    end

    @import.reload
    render :show
  rescue ActiveRecord::RecordInvalid => e
    errors = e.record&.errors&.full_messages || [ e.message ]
    render json: {
      error: "validation_failed",
      message: errors.to_sentence.presence || "Import configuration could not be updated",
      errors: errors
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "ImportsController#update_configuration error: #{e.message}"
    render json: { error: "internal_server_error", message: "Import configuration could not be updated." }, status: :internal_server_error
  end

  def qif_category_selection
    render json: { data: qif_category_selection_payload(@import) }
  rescue StandardError => e
    Rails.logger.error "ImportsController#qif_category_selection error: #{e.message}"
    render json: { error: "internal_server_error", message: "QIF category selection could not be loaded." }, status: :internal_server_error
  end

  def update_qif_category_selection
    selection_params = qif_category_selection_params
    selected_format = selection_params[:date_format]

    if selected_format.present? && !qif_date_format_values.include?(selected_format)
      return render json: {
        error: "invalid_date_format",
        message: "Date format is not valid for this QIF import."
      }, status: :unprocessable_entity
    end

    format_changed = false
    if selected_format.present? && selected_format != @import.qif_date_format
      format_changed = true
      @import.qif_date_format = selected_format
      @import.update_column(:column_mappings, @import.column_mappings)
      @import.generate_rows_from_csv
      @import.sync_mappings
    end

    all_categories = @import.row_categories
    all_tags = @import.row_tags

    selected_categories = parameter_provided?(selection_params, :categories) ? Array(selection_params[:categories]).reject(&:blank?) : all_categories
    selected_tags = parameter_provided?(selection_params, :tags) ? Array(selection_params[:tags]).reject(&:blank?) : all_tags

    deselected_categories = all_categories - selected_categories
    deselected_tags = all_tags - selected_tags

    ActiveRecord::Base.transaction do
      @import.rows.where(category: deselected_categories).update_all(category: "") if deselected_categories.any?

      if deselected_tags.any?
        @import.rows.where.not(tags: [ nil, "" ]).find_each do |row|
          remaining_tags = row.tags_list - deselected_tags
          remaining_tags.reject!(&:blank?)
          updated_tags = remaining_tags.join("|")
          row.update_column(:tags, updated_tags) if updated_tags != row.tags.to_s
        end
      end

      @import.sync_mappings unless format_changed
    end

    @import.reload
    render json: { data: qif_category_selection_payload(@import) }
  rescue ActiveRecord::RecordInvalid => e
    errors = e.record&.errors&.full_messages || [ e.message ]
    render json: {
      error: "validation_failed",
      message: errors.to_sentence.presence || "QIF category selection could not be updated",
      errors: errors
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "ImportsController#update_qif_category_selection error: #{e.message}"
    render json: { error: "internal_server_error", message: "QIF category selection could not be updated." }, status: :internal_server_error
  end

  def apply_template
    template = @import.suggested_template
    unless template
      return render json: {
        error: "template_not_found",
        message: "No suggested import template was found."
      }, status: :unprocessable_entity
    end

    @import.apply_template!(template)
    @import.reload

    render :show
  rescue ActiveRecord::RecordInvalid => e
    errors = e.record&.errors&.full_messages || [ e.message ]
    render json: {
      error: "validation_failed",
      message: errors.to_sentence.presence || "Import template could not be applied",
      errors: errors
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "ImportsController#apply_template error: #{e.message}"
    render json: { error: "internal_server_error", message: "Import template could not be applied." }, status: :internal_server_error
  end

  def update_row
    @row = @import.rows.find(params[:row_id])
    @row.update_and_sync(import_row_params)
    @row.valid?
    @row_mapping_lookup = @import.mappings.includes(:mappable).index_by { |mapping| [ mapping.type, mapping.key.to_s ] }

    render json: { data: import_row_payload(@row) }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found", message: "Import row not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: e.record.errors.full_messages.to_sentence,
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "ImportsController#update_row error: #{e.message}"
    render json: { error: "internal_server_error", message: "Import row could not be updated." }, status: :internal_server_error
  end

  def update_mapping
    mapping = @import.mappings.find(params[:mapping_id])
    mapping_class = IMPORT_MAPPING_CLASSES.fetch(mapping.type)

    mapping.update!(
      create_when_empty: create_when_empty?(mapping_class),
      mappable: mapping_mappable(mapping),
      value: import_mapping_params[:value]
    )

    render json: { data: import_mapping_payload(mapping.reload) }
  rescue KeyError
    render json: { error: "validation_failed", message: "Unsupported import mapping type" }, status: :unprocessable_entity
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found", message: "Import mapping not found" }, status: :not_found
  rescue ActiveRecord::RecordInvalid => e
    render json: {
      error: "validation_failed",
      message: e.record.errors.full_messages.to_sentence,
      errors: e.record.errors.full_messages
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "ImportsController#update_mapping error: #{e.message}"
    render json: { error: "internal_server_error", message: "Import mapping could not be updated." }, status: :internal_server_error
  end

  def create
    family = current_resource_owner.family

    # 1. Determine type and validate
    type = params[:type].to_s
    type = "TransactionImport" unless Import::TYPES.include?(type)
    return create_sure_import(family) if type == "SureImport"
    return create_qif_import(family) if type == "QifImport"
    return create_pdf_import(family) if type == "PdfImport" || pdf_upload_request?

    # 2. Build the import object with permitted config attributes
    @import = family.imports.build(import_config_params.merge(type: type))
    @import.account_id = params[:account_id] if params[:account_id].present?

    # 3. Attach the uploaded file if present (with validation)
    if params[:file].present?
      file = params[:file]

      if file.size > Import.max_csv_size
        return render json: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{Import.max_csv_size / 1.megabyte}MB."
        }, status: :unprocessable_entity
      end

      unless Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
        return render json: {
          error: "invalid_file_type",
          message: "Invalid file type. Please upload a CSV file."
        }, status: :unprocessable_entity
      end

      @import.raw_file_str = file.read
    elsif params[:raw_file_content].present?
      if params[:raw_file_content].bytesize > Import.max_csv_size
        return render json: {
          error: "content_too_large",
          message: "Content is too large. Maximum size is #{Import.max_csv_size / 1.megabyte}MB."
        }, status: :unprocessable_entity
      end

      @import.raw_file_str = params[:raw_file_content]
    end

    # 4. Save and Process
    if @import.save
      # Generate rows if file content was provided
      if @import.uploaded?
        begin
          @import.generate_rows_from_csv
          @import.reload
        rescue StandardError => e
          Rails.logger.error "Row generation failed for import #{@import.id}: #{e.message}"
        end
      end

      # If the import is configured (has rows), we can try to auto-publish or just leave it as pending
      # For API simplicity, if enough info is provided, we might want to trigger processing

      if @import.configured? && params[:publish] == "true"
        @import.publish_later
      end

      render :show, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "Import could not be created",
        errors: @import.errors.full_messages
      }, status: :unprocessable_entity
    end

  rescue StandardError => e
    Rails.logger.error "ImportsController#create error: #{e.message}"
    render json: { error: "internal_server_error", message: "An unexpected error occurred." }, status: :internal_server_error
  end

  def preflight
    preflight_result = Import::Preflight.new(family: current_resource_owner.family, params: preflight_params).call
    render json: preflight_result.payload, status: preflight_result.status
  rescue ActiveRecord::RecordNotFound
    render json: {
      error: "record_not_found",
      message: "The requested resource was not found"
    }, status: :not_found
  rescue CSV::MalformedCSVError => e
    render json: {
      error: "invalid_csv",
      message: "CSV content could not be parsed",
      errors: [ e.message ]
    }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "ImportsController#preflight error: #{e.message}"
    e.backtrace&.each { |line| Rails.logger.error line }

    render json: {
      error: "internal_server_error",
      message: "Import preflight could not be completed."
    }, status: :internal_server_error
  end

  def publish
    @import.publish_later
    @import.reload

    render :show, status: :accepted
  rescue Import::MaxRowCountExceededError
    render json: {
      error: "max_row_count_exceeded",
      message: "Import has too many rows to publish.",
      errors: [ "Maximum row count is #{@import.max_row_count}" ]
    }, status: :unprocessable_entity
  rescue StandardError => e
    render json: {
      error: "not_publishable",
      message: "Import could not be queued for processing.",
      errors: [ e.message ]
    }, status: :unprocessable_entity
  end

  def revert
    @import.revert_later
    @import.reload

    render :show, status: :accepted
  rescue StandardError => e
    render json: {
      error: "not_revertable",
      message: "Import could not be queued for revert.",
      errors: [ e.message ]
    }, status: :unprocessable_entity
  end

  def destroy
    @import.destroy

    render json: { message: "Import deleted successfully" }, status: :ok
  end

  private

    def set_import
      @import = import_scope.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_import_not_found
    end

    def set_import_with_rows
      @import = import_scope.includes(:rows).find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render_import_not_found
    end

    def import_scope
      current_resource_owner.family.imports
    end

    def render_import_not_found
      render json: { error: "not_found", message: "Import not found" }, status: :not_found
    end

    def ensure_import_write_permission
      return if @import.account_statement.blank? || @import.account_statement.manageable_by?(current_resource_owner)

      render_forbidden("You do not have permission to manage this import")
    end

    def render_forbidden(message)
      render json: {
        error: "forbidden",
        message: message
      }, status: :forbidden
    end

    def ensure_qif_import
      return if @import.is_a?(QifImport)

      render json: {
        error: "unsupported_import_type",
        message: "QIF category selection is only available for QIF imports."
      }, status: :unprocessable_entity
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def import_config_params
      params.permit(
        :date_col_label,
        :amount_col_label,
        :name_col_label,
        :category_col_label,
        :tags_col_label,
        :notes_col_label,
        :account_col_label,
        :qty_col_label,
        :ticker_col_label,
        :price_col_label,
        :entity_type_col_label,
        :currency_col_label,
        :exchange_operating_mic_col_label,
        :date_format,
        :number_format,
        :signage_convention,
        :col_sep,
        :amount_type_strategy,
        :amount_type_identifier_value,
        :amount_type_inflow_value,
        :rows_to_skip
      )
    end

    def import_configuration_params
      source = params[:import].present? ? params.require(:import) : params
      source.permit(
        :date_col_label,
        :amount_col_label,
        :name_col_label,
        :category_col_label,
        :tags_col_label,
        :account_col_label,
        :qty_col_label,
        :ticker_col_label,
        :exchange_operating_mic_col_label,
        :price_col_label,
        :entity_type_col_label,
        :notes_col_label,
        :currency_col_label,
        :date_format,
        :number_format,
        :signage_convention,
        :amount_type_strategy,
        :amount_type_identifier_value,
        :amount_type_inflow_value,
        :rows_to_skip
      )
    end

    def import_update_params
      source = params[:import].present? ? params.require(:import) : params
      source.permit(:account_id)
    end

    def import_account_id
      import_update_params[:account_id]
    end

    def import_account_id_provided?
      source = params[:import].present? ? params.require(:import) : params
      source.key?(:account_id) || source.key?("account_id")
    end

    def target_import_account
      account_id = import_account_id
      unless Api::V1::BaseController.valid_uuid?(account_id)
        render json: { error: "not_found", message: "Account not found" }, status: :not_found
        return nil
      end

      current_resource_owner.accessible_accounts.find(account_id)
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Account not found" }, status: :not_found
      nil
    end

    def can_manage_import_account?(account)
      account.permission_for(current_resource_owner).in?(%i[owner full_control])
    end

    def assign_import_account!(account)
      if @import.is_a?(PdfImport)
        if account.present?
          @import.assign_account!(account)
        else
          ActiveRecord::Base.transaction do
            @import.update!(account: nil)
            @import.account_statement&.unlink!
          end
        end
      else
        @import.update!(account: account)
      end
    end

    def qif_category_selection_params
      source = params[:qif_category_selection].present? ? params.require(:qif_category_selection) : params
      source.permit(:date_format, categories: [], tags: [])
    end

    def parameter_provided?(source, key)
      source.key?(key) || source.key?(key.to_s)
    end

    def refresh_only_configuration_update?
      ActiveModel::Type::Boolean.new.cast(params[:refresh_only])
    end

    def import_row_params
      source = params[:import_row].present? ? params.require(:import_row) : params
      source.permit(
        :type,
        :account,
        :date,
        :qty,
        :ticker,
        :exchange_operating_mic,
        :price,
        :amount,
        :currency,
        :name,
        :category,
        :tags,
        :entity_type,
        :notes,
        :category_color,
        :category_classification,
        :category_parent,
        :category_icon,
        :active,
        :effective_date,
        :conditions,
        :actions
      )
    end

    def import_mapping_params
      source = params[:import_mapping].present? ? params.require(:import_mapping) : params
      source.permit(:mappable_id, :value)
    end

    def create_when_empty?(mapping_class)
      import_mapping_params[:mappable_id] == mapping_class::CREATE_NEW_KEY
    end

    def mapping_mappable(mapping)
      return nil if create_when_empty?(IMPORT_MAPPING_CLASSES.fetch(mapping.type))
      return nil if import_mapping_params[:mappable_id].blank?

      mappable_class = mapping.mappable_class
      return nil unless mappable_class

      mappable_class.where(family: current_resource_owner.family).find_by(id: import_mapping_params[:mappable_id])
    end

    def import_row_payload(row)
      {
        id: row.id,
        row_number: row.source_row_number,
        valid: row.errors.empty?,
        errors: row.errors.full_messages,
        fields: {
          account: row.account,
          date: row.date,
          qty: row.qty,
          ticker: row.ticker,
          exchange_operating_mic: row.exchange_operating_mic,
          price: row.price,
          amount: row.amount,
          currency: row.currency,
          name: row.name,
          category: row.category,
          tags: row.tags,
          entity_type: row.entity_type,
          notes: row.notes,
          active: row.active,
          effective_date: row.effective_date,
          conditions: row.conditions,
          actions: row.actions
        },
        mappings: import_row_mappings_payload(row)
      }
    end

    def import_row_mappings_payload(row)
      mappings = {}
      mappings[:account] = import_mapping_summary("Import::AccountMapping", row.account) if row.account.present?
      mappings[:category] = import_mapping_summary("Import::CategoryMapping", row.category) if row.category.present?
      mappings[:account_type] = import_mapping_summary("Import::AccountTypeMapping", row.entity_type) if row.entity_type.present?
      mappings[:tags] = row.tags_list.reject(&:blank?).map { |tag| import_mapping_summary("Import::TagMapping", tag) }
      mappings
    end

    def import_mapping_summary(type, key)
      mapping = @row_mapping_lookup[[ type, key.to_s ]]

      if mapping
        import_mapping_payload(mapping)
      else
        {
          key: key,
          type: type,
          value: nil,
          create_when_empty: false,
          creatable: false,
          mappable: nil
        }
      end
    end

    def import_mapping_payload(mapping)
      {
        id: mapping.id,
        key: mapping.key,
        type: mapping.type,
        value: mapping.value,
        values_count: mapping.values_count,
        requires_selection: mapping.requires_selection?,
        create_when_empty: mapping.create_when_empty,
        creatable: mapping.creatable?,
        mappable: import_mapping_mappable_payload(mapping)
      }
    end

    def import_mappings_payload(import)
      {
        import_id: import.id,
        steps: import.mapping_steps.map { |mapping_class| import_mapping_step_payload(import, mapping_class) },
        summary: import_mapping_confirmation_summary(import)
      }
    end

    def import_mapping_step_payload(import, mapping_class)
      {
        type: mapping_class.name,
        resource_kind: import_mapping_resource_kind(mapping_class),
        source_label: import_mapping_label(mapping_class),
        target_label: "#{import_mapping_label(mapping_class)} in Sure",
        mappings: mapping_class.for_import(import).includes(:mappable).sort_by { |mapping| mapping.key.to_s.downcase }.map do |mapping|
          import_mapping_payload(mapping)
        end
      }
    end

    def import_mapping_resource_kind(mapping_class)
      mapping_class.name.demodulize.delete_suffix("Mapping").underscore
    end

    def import_mapping_label(mapping_class)
      import_mapping_resource_kind(mapping_class).humanize
    end

    def import_mapping_confirmation_summary(import)
      {
        transactions_count: import.rows_count,
        categories_count: import.mappings.categories.creational.count,
        tags_count: import.mappings.tags.creational.count
      }
    end

    def import_mapping_mappable_payload(mapping)
      return nil unless mapping.mappable

      {
        id: mapping.mappable.id,
        type: mapping.mappable_type,
        name: mapping.mappable.try(:name)
      }
    end

    def preflight_params
      params.permit(*Import::Preflight::PARAM_KEYS)
    end

    def qif_date_format_values
      @qif_date_format_values ||= @import.valid_date_formats_with_preview.map { |format| format[:format] }
    end

    def qif_category_selection_payload(import)
      valid_formats = import.valid_date_formats_with_preview
      category_counts = import.rows.group(:category).count.reject { |key, _| key.blank? }
      tag_counts = qif_tag_counts(import)
      split_categories = import.split_categories

      {
        import_id: import.id,
        account_id: import.account_id,
        qif_account_type: import.qif_account_type,
        qif_date_format: import.qif_date_format,
        categories_selected: import.categories_selected?,
        has_split_transactions: import.has_split_transactions?,
        date_formats: valid_formats.map do |format|
          {
            label: format[:label],
            format: format[:format],
            preview: format[:preview],
            selected: format[:format] == import.qif_date_format
          }
        end,
        categories: import.row_categories.map do |category|
          split = split_categories.include?(category)
          {
            name: category,
            count: category_counts[category] || 0,
            split: split,
            recommended_selected: !split
          }
        end,
        tags: import.row_tags.map do |tag|
          {
            name: tag,
            count: tag_counts[tag] || 0,
            recommended_selected: true
          }
        end,
        stats: {
          rows_count: import.rows_count,
          categories_count: import.row_categories.count,
          tags_count: import.row_tags.count
        }
      }
    end

    def qif_tag_counts(import)
      counts = Hash.new(0)
      import.rows.find_each do |row|
        row.tags_list.each { |tag| counts[tag] += 1 unless tag.blank? }
      end
      counts
    end

    def create_qif_import(family)
      content = qif_import_content
      return unless content

      account = family.accounts.find_by(id: params[:account_id])
      unless account
        return render json: {
          error: "account_required",
          message: "A valid account_id is required for QIF imports."
        }, status: :unprocessable_entity
      end

      normalized_content = QifParser.normalize_encoding(content)
      unless QifParser.valid?(normalized_content)
        return render json: {
          error: "invalid_qif",
          message: "QIF content is invalid."
        }, status: :unprocessable_entity
      end

      ActiveRecord::Base.transaction do
        @import = family.imports.create!(
          type: "QifImport",
          account: account,
          raw_file_str: normalized_content
        )
        @import.generate_rows_from_csv
        @import.sync_mappings
      end
      @import.reload

      render :show, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: {
        error: "validation_failed",
        message: "Import could not be created",
        errors: e.record&.errors&.full_messages || @import&.errors&.full_messages || []
      }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error "QIF import creation failed: #{e.message}"
      render json: {
        error: "internal_server_error",
        message: "Import could not be created"
      }, status: :internal_server_error
    end

    def create_pdf_import(family)
      unless AccountStatement.statement_manager?(current_resource_owner)
        return render_forbidden("PDF imports require a family admin or member")
      end

      file = params[:file]
      unless file.present?
        return render json: {
          error: "missing_file",
          message: "Provide a PDF file."
        }, status: :unprocessable_entity
      end

      if file.size > Import::MAX_PDF_SIZE
        return render json: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{Import::MAX_PDF_SIZE / 1.megabyte}MB."
        }, status: :unprocessable_entity
      end

      unless Import::ALLOWED_PDF_MIME_TYPES.include?(file.content_type)
        return render json: {
          error: "invalid_file_type",
          message: "Invalid file type. Please upload a PDF file."
        }, status: :unprocessable_entity
      end

      unless valid_pdf_file?(file)
        return render json: {
          error: "invalid_pdf",
          message: "PDF file is invalid."
        }, status: :unprocessable_entity
      end

      account = pdf_import_account
      return if performed?

      if account && !can_manage_import_account?(account)
        return render_forbidden("You do not have permission to assign imports to this account")
      end

      @import = PdfImport.create_from_upload!(family: family, file: file, user: current_resource_owner)
      @import.assign_account!(account) if account
      @import.process_with_ai_later
      @import.reload

      render :show, status: :created
    rescue AccountStatement::DuplicateUploadError
      render json: {
        error: "duplicate_upload",
        message: "A matching account statement already exists."
      }, status: :unprocessable_entity
    rescue AccountStatement::InvalidUploadError
      render json: {
        error: "invalid_pdf",
        message: "PDF file is invalid."
      }, status: :unprocessable_entity
    rescue ActiveRecord::RecordInvalid => e
      render json: {
        error: "validation_failed",
        message: "Import could not be created",
        errors: e.record&.errors&.full_messages || @import&.errors&.full_messages || []
      }, status: :unprocessable_entity
    rescue StandardError => e
      Rails.logger.error "PDF import creation failed: #{e.message}"
      render json: {
        error: "internal_server_error",
        message: "Import could not be created"
      }, status: :internal_server_error
    end

    def pdf_upload_request?
      file = params[:file]
      file.present? && file.respond_to?(:content_type) && Import::ALLOWED_PDF_MIME_TYPES.include?(file.content_type)
    end

    def valid_pdf_file?(file)
      header = file.read(5)
      file.rewind
      header&.start_with?("%PDF-")
    end

    def pdf_import_account
      return nil if import_account_id.blank?

      target_import_account
    end

    def qif_import_content
      if params[:file].present?
        qif_import_file_content(params[:file])
      elsif params[:raw_file_content].present?
        qif_import_raw_content(params[:raw_file_content].to_s)
      else
        render json: {
          error: "missing_content",
          message: "Provide a QIF file or raw_file_content."
        }, status: :unprocessable_entity
        nil
      end
    end

    def qif_import_file_content(file)
      if file.size > Import.max_csv_size
        render json: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{Import.max_csv_size / 1.megabyte}MB."
        }, status: :unprocessable_entity
        return
      end

      extension = File.extname(file.original_filename.to_s).downcase
      unless extension == ".qif" || Import::ALLOWED_CSV_MIME_TYPES.include?(file.content_type)
        render json: {
          error: "invalid_file_type",
          message: "Invalid file type. Please upload a QIF file."
        }, status: :unprocessable_entity
        return
      end

      file.read
    end

    def qif_import_raw_content(content)
      if content.bytesize > Import.max_csv_size
        render json: {
          error: "content_too_large",
          message: "Content is too large. Maximum size is #{Import.max_csv_size / 1.megabyte}MB."
        }, status: :unprocessable_entity
        return
      end

      content
    end

    def create_sure_import(family)
      content, filename, content_type = sure_import_upload_attributes
      return unless content

      begin
        @import = persist_sure_import!(family, content, filename, content_type)
      rescue ActiveRecord::RecordInvalid => e
        render json: {
          error: "validation_failed",
          message: "Import could not be created",
          errors: e.record&.errors&.full_messages || @import&.errors&.full_messages || []
        }, status: :unprocessable_entity
        return
      rescue StandardError => e
        Rails.logger.error "Sure import creation failed: #{e.message}"
        render json: {
          error: "internal_server_error",
          message: "Import could not be created"
        }, status: :internal_server_error
        return
      end

      begin
        @import.publish_later if params[:publish] == "true"
      rescue Import::MaxRowCountExceededError
        render json: {
          error: "max_row_count_exceeded",
          message: "Import was uploaded but has too many rows to publish automatically.",
          import_id: @import.id
        }, status: :unprocessable_entity
        return
      rescue SureImport::PreflightError
        render json: {
          error: "preflight_failed",
          message: "Import was uploaded but did not pass Sure NDJSON preflight.",
          errors: sure_import_error_lines,
          import_id: @import.id
        }, status: :unprocessable_entity
        return
      rescue SureImport::NotPublishableError => e
        Rails.logger.warn "Sure import not publishable for import #{@import.id}: #{e.message}"
        render json: {
          error: "not_publishable",
          message: "Import was uploaded but has no publishable records.",
          import_id: @import.id
        }, status: :unprocessable_entity
        return
      rescue StandardError => e
        Rails.logger.error "Sure import publish failed for import #{@import.id}: #{e.message}"
        restore_pending_sure_import_after_publish_failure
        render json: {
          error: "publish_failed",
          message: "Import was uploaded but could not be queued for processing.",
          import_id: @import.id
        }, status: :internal_server_error
        return
      end

      render :show, status: :created
    end

    def persist_sure_import!(family, content, filename, content_type)
      import = nil
      import = family.imports.create!(type: "SureImport")
      import.ndjson_file.attach(
        io: StringIO.new(content),
        filename: filename,
        content_type: content_type
      )
      import.sync_ndjson_rows_count!
      import
    rescue StandardError => e
      clean_up_failed_sure_import(import)
      raise
    end

    def restore_pending_sure_import_after_publish_failure
      # Import#publish_later flips status to importing before enqueueing the job.
      @import.update_column(:status, "pending") if @import&.persisted? && @import.importing?
    end

    def sure_import_error_lines
      @import.error.to_s.lines.map(&:strip).reject(&:blank?)
    end

    def clean_up_failed_sure_import(import)
      return unless import

      begin
        import.ndjson_file.purge if import.ndjson_file.attached?
      rescue StandardError => e
        Rails.logger.warn "Failed to purge Sure import attachment #{import.id}: #{e.message}"
      ensure
        import.destroy if import.persisted?
      end
    end

    def sure_import_upload_attributes
      if params[:file].present?
        sure_import_file_upload_attributes(params[:file])
      elsif params[:raw_file_content].present?
        sure_import_raw_content_attributes(params[:raw_file_content].to_s)
      else
        render json: {
          error: "missing_content",
          message: "Provide a Sure NDJSON file or raw_file_content."
        }, status: :unprocessable_entity
        nil
      end
    end

    def sure_import_file_upload_attributes(file)
      if file.size > SureImport.max_ndjson_size
        render json: {
          error: "file_too_large",
          message: "File is too large. Maximum size is #{SureImport.max_ndjson_size / 1.megabyte}MB."
        }, status: :unprocessable_entity
        return
      end

      extension = File.extname(file.original_filename.to_s).downcase
      unless SureImport::ALLOWED_NDJSON_CONTENT_TYPES.include?(file.content_type) || extension.in?(%w[.ndjson .json])
        render json: {
          error: "invalid_file_type",
          message: "Invalid file type. Please upload a Sure NDJSON file."
        }, status: :unprocessable_entity
        return
      end

      content = file.read
      sure_import_validated_attributes(
        content: content,
        filename: file.original_filename.presence || "sure-import.ndjson",
        content_type: file.content_type.presence || "application/x-ndjson"
      )
    end

    def sure_import_raw_content_attributes(content)
      if content.bytesize > SureImport.max_ndjson_size
        render json: {
          error: "content_too_large",
          message: "Content is too large. Maximum size is #{SureImport.max_ndjson_size / 1.megabyte}MB."
        }, status: :unprocessable_entity
        return
      end

      sure_import_validated_attributes(
        content: content,
        filename: "sure-import.ndjson",
        content_type: "application/x-ndjson"
      )
    end

    def sure_import_validated_attributes(content:, filename:, content_type:)
      unless SureImport.valid_ndjson_first_line?(content)
        render json: {
          error: "invalid_ndjson",
          message: "Invalid Sure NDJSON content."
        }, status: :unprocessable_entity
        return
      end

      [ content, filename, content_type ]
    end

    def safe_page_param
      page = params[:page].to_i
      page > 0 ? page : 1
    end

    def safe_per_page_param
      per_page = params[:per_page].to_i
      (1..100).include?(per_page) ? per_page : 25
    end
end
