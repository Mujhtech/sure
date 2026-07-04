# frozen_string_literal: true

class Api::V1::AccountStatementsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope, only: %i[index show download]
  before_action :ensure_write_scope, only: %i[create update destroy link unlink reject]
  before_action :ensure_statement_manager!, only: %i[index create update destroy link unlink reject]
  before_action :set_statement, only: %i[show update destroy download link unlink reject]
  before_action :ensure_statement_manageable!, only: %i[update destroy link unlink reject]

  def index
    @per_page = safe_per_page_param
    statements_query = visible_statement_scope
      .with_attached_original_file
      .includes(:account, :suggested_account)
      .ordered

    statements_query = apply_filters(statements_query)
    return if performed?

    @pagy, @account_statements = pagy(
      statements_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  end

  def show
    render :show
  end

  def create
    files = statement_uploads
    if files.empty?
      render_validation_error("No files selected for upload")
      return
    end

    account = target_account
    return if performed?

    if account && !can_manage_account?(account)
      render_forbidden("You do not have permission to upload statements for this account")
      return
    end

    @account_statements = []
    @duplicates = []
    @upload_errors = []

    files.each do |file|
      prepared_upload = AccountStatement.prepare_upload!(file)
      @account_statements << AccountStatement.create_from_prepared_upload!(
        family: current_resource_owner.family,
        account: account,
        prepared_upload: prepared_upload
      )
    rescue AccountStatement::DuplicateUploadError => e
      @duplicates << e.statement
    rescue AccountStatement::InvalidUploadError
      @upload_errors << "Invalid file type or file contents"
    rescue ActiveRecord::RecordInvalid => e
      @upload_errors << e.record.errors.full_messages.to_sentence
    end

    if @account_statements.any?
      render :create, status: :created
    else
      render json: {
        error: "validation_failed",
        message: "No account statements were uploaded",
        duplicate_statement_ids: @duplicates.map(&:id),
        errors: @upload_errors
      }, status: :unprocessable_entity
    end
  end

  def update
    target = target_account if statement_account_id_provided?
    return if performed?

    if target && !can_manage_account?(target)
      render_forbidden("You do not have permission to link statements to this account")
      return
    end

    attrs = statement_params.to_h
    attrs[:account] = target if statement_account_id_provided?

    @statement.assign_attributes(attrs)
    @statement.assign_account_match if @statement.account.nil? && !@statement.rejected?

    if @statement.save
      render :show
    else
      render_statement_validation_error
    end
  end

  def link
    account_id = params[:account_id].presence || @statement.suggested_account_id
    if account_id.blank?
      render_validation_error("account_id is required")
      return
    end

    account = current_resource_owner.accessible_accounts.find(account_id)
    unless can_manage_account?(account)
      render_forbidden("You do not have permission to link statements to this account")
      return
    end

    @statement.link_to_account!(account)

    render :show
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not_found", message: "Account not found" }, status: :not_found
  end

  def unlink
    @statement.unlink!

    render :show
  end

  def reject
    @statement.reject_match!

    render :show
  end

  def destroy
    @statement.destroy!

    render json: { message: "Account statement deleted successfully" }, status: :ok
  end

  def download
    redirect_to rails_blob_url(@statement.original_file, disposition: "attachment"), allow_other_host: true
  end

  private

    def set_statement
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @statement = current_resource_owner.family.account_statements
        .with_attached_original_file
        .includes(:account, :suggested_account)
        .find(params[:id])
      raise ActiveRecord::RecordNotFound unless @statement.viewable_by?(current_resource_owner)
    rescue ActiveRecord::RecordNotFound
      render json: {
        error: "not_found",
        message: "Account statement not found"
      }, status: :not_found
    end

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_statement_manager!
      return if AccountStatement.statement_manager?(current_resource_owner)

      render_forbidden("Account statements require a family admin or member")
    end

    def ensure_statement_manageable!
      return if @statement.manageable_by?(current_resource_owner)

      render_forbidden("You do not have permission to manage this account statement")
    end

    def visible_statement_scope
      accessible_account_ids = current_resource_owner.accessible_accounts.select(:id)
      base = current_resource_owner.family.account_statements

      base.where(account_id: nil).or(base.where(account_id: accessible_account_ids))
    end

    def apply_filters(query)
      if params[:account_id].present?
        raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:account_id])

        account = current_resource_owner.accessible_accounts.find(params[:account_id])
        query = query.where(account_id: account.id)
      end

      if params[:review_status].present?
        unless AccountStatement.review_statuses.key?(params[:review_status])
          render_validation_error("review_status must be one of: #{AccountStatement.review_statuses.keys.join(', ')}")
          return query
        end

        query = query.where(review_status: params[:review_status])
      end

      if params[:upload_status].present?
        unless AccountStatement.upload_statuses.key?(params[:upload_status])
          render_validation_error("upload_status must be one of: #{AccountStatement.upload_statuses.keys.join(', ')}")
          return query
        end

        query = query.where(upload_status: params[:upload_status])
      end

      query
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Account not found" }, status: :not_found
      query
    end

    def statement_uploads
      container = params.fetch(:account_statement, ActionController::Parameters.new)
      uploads = if container[:files].present?
        Array(container[:files])
      elsif params[:files].present?
        Array(params[:files])
      elsif params[:file].present?
        [ params[:file] ]
      else
        []
      end

      uploads.select { |file| file.present? && file.respond_to?(:read) }
    end

    def statement_params
      params.require(:account_statement).permit(
        :institution_name_hint,
        :account_name_hint,
        :account_last4_hint,
        :period_start_on,
        :period_end_on,
        :opening_balance,
        :closing_balance,
        :currency
      )
    end

    def target_account
      account_id = statement_account_id.presence
      return nil if account_id.blank?

      raise ActiveRecord::RecordNotFound unless valid_uuid?(account_id)

      current_resource_owner.accessible_accounts.find(account_id)
    rescue ActiveRecord::RecordNotFound
      render json: { error: "not_found", message: "Account not found" }, status: :not_found
      nil
    end

    def statement_account_id
      params.fetch(:account_statement, ActionController::Parameters.new)[:account_id].presence || params[:account_id]
    end

    def statement_account_id_provided?
      params.fetch(:account_statement, ActionController::Parameters.new).key?(:account_id) || params.key?(:account_id)
    end

    def can_manage_account?(account)
      account.permission_for(current_resource_owner).in?(%i[owner full_control])
    end

    def render_statement_validation_error
      render json: {
        error: "validation_failed",
        message: "Account statement could not be saved",
        errors: @statement.errors.full_messages
      }, status: :unprocessable_entity
    end

    def render_forbidden(message)
      render json: {
        error: "forbidden",
        message: message
      }, status: :forbidden
    end
end
