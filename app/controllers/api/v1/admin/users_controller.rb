# frozen_string_literal: true

class Api::V1::Admin::UsersController < Api::V1::BaseController
  TRIAL_STATUS_FILTERS = %w[expiring_soon trialing].freeze

  before_action :ensure_read_scope, only: :index
  before_action :ensure_write_scope, only: :update
  before_action :ensure_super_admin!
  before_action :set_user, only: :update

  def index
    users = filtered_users
    family_ids = users.map(&:family_id).uniq
    user_ids = users.map(&:id).uniq

    @accounts_count_by_family = Account.where(family_id: family_ids).group(:family_id).count
    @entries_count_by_family = Entry.joins(:account).where(accounts: { family_id: family_ids }).group("accounts.family_id").count
    @last_login_by_user = Session.where(user_id: user_ids).group(:user_id).maximum(:created_at)
    @sessions_count_by_user = Session.where(user_id: user_ids).group(:user_id).count
    @invitations_by_family = Invitation.pending.where(family_id: family_ids).group_by(&:family_id)

    render_json({
      families: family_groups_payload(users),
      filters: filters_payload,
      summary: summary_payload
    })
  end

  def update
    return render_forbidden("You cannot change your own role") if @user.id == current_resource_owner.id

    if @user.update(user_params)
      Rails.logger.info(
        "[Api::V1::Admin::Users] Role changed - " \
        "by_user_id=#{current_resource_owner.id} " \
        "target_user_id=#{@user.id} " \
        "new_role=#{@user.role}"
      )

      render_json({
        message: "User role updated successfully",
        user: user_payload(@user)
      })
    else
      render_model_errors(@user)
    end
  end

  private

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def ensure_super_admin!
      return if performed?
      return if current_resource_owner&.super_admin?

      render_forbidden("Users can only be managed by a super admin")
    end

    def render_forbidden(message)
      render_json({ error: "forbidden", message: message }, status: :forbidden)
    end

    def set_user
      @user = User.find(params[:id])
    end

    def user_params
      permitted = params.require(:user).permit(:role)
      role = permitted[:role].to_s

      unless User.roles.key?(role)
        raise InvalidFilterError, "role must be one of #{User.roles.keys.join(", ")}"
      end

      permitted
    end

    def filtered_users
      scope = User.left_joins(family: :subscription).includes(family: :subscription)
      scope = apply_role_filter(scope)
      scope = apply_trial_filter(scope)

      scope.order(
        Arel.sql(
          "CASE " \
          "WHEN subscriptions.status = 'trialing' THEN 0 " \
          "WHEN subscriptions.id IS NULL THEN 1 " \
          "ELSE 2 END, " \
          "subscriptions.trial_ends_at ASC NULLS LAST, users.email ASC"
        )
      )
    end

    def apply_role_filter(scope)
      role = params[:role].to_s.presence
      return scope unless role

      unless User.roles.key?(role)
        raise InvalidFilterError, "role must be one of #{User.roles.keys.join(", ")}"
      end

      scope.where(role: role)
    end

    def apply_trial_filter(scope)
      trial_status = params[:trial_status].to_s.presence
      return scope unless trial_status

      unless TRIAL_STATUS_FILTERS.include?(trial_status)
        raise InvalidFilterError, "trial_status must be expiring_soon or trialing"
      end

      case trial_status
      when "expiring_soon"
        scope.where(subscriptions: { status: :trialing })
          .where(subscriptions: { trial_ends_at: Time.current..7.days.from_now })
      when "trialing"
        scope.where(subscriptions: { status: :trialing })
      end
    end

    def family_groups_payload(users)
      users.group_by(&:family).sort_by do |family, _family_users|
        -(@entries_count_by_family[family.id] || 0)
      end.map do |family, family_users|
        family_payload(family, family_users)
      end
    end

    def family_payload(family, users)
      {
        id: family.id,
        name: family.name,
        currency: family.currency,
        users_count: users.size,
        accounts_count: @accounts_count_by_family[family.id] || 0,
        entries_count: @entries_count_by_family[family.id] || 0,
        subscription: subscription_payload(family.subscription),
        pending_invitations: pending_invitation_payloads(family),
        users: users.map { |user| user_payload(user) }
      }
    end

    def subscription_payload(subscription)
      return nil unless subscription

      {
        id: subscription.id,
        status: subscription.status,
        trialing: subscription.trialing?,
        active: subscription.active?,
        trial_ends_at: subscription.trial_ends_at&.iso8601,
        cancel_at_period_end: subscription.cancel_at_period_end?,
        created_at: subscription.created_at.iso8601,
        updated_at: subscription.updated_at.iso8601
      }
    end

    def pending_invitation_payloads(family)
      (@invitations_by_family[family.id] || []).map do |invitation|
        {
          id: invitation.id,
          email: invitation.email,
          role: invitation.role,
          expires_at: invitation.expires_at.iso8601,
          created_at: invitation.created_at.iso8601,
          updated_at: invitation.updated_at.iso8601
        }
      end
    end

    def user_payload(user)
      {
        id: user.id,
        email: user.email,
        display_name: user.display_name,
        initials: user.initials,
        role: user.role,
        active: user.active?,
        current_user: user.id == current_resource_owner.id,
        last_login_at: @last_login_by_user&.[](user.id)&.iso8601,
        sessions_count: @sessions_count_by_user&.[](user.id) || user.sessions.count,
        family_id: user.family_id,
        created_at: user.created_at.iso8601,
        updated_at: user.updated_at.iso8601
      }
    end

    def filters_payload
      {
        roles: User.roles.keys,
        trial_statuses: TRIAL_STATUS_FILTERS
      }
    end

    def summary_payload
      {
        trials_expiring_in_7_days: Subscription
          .where(status: :trialing)
          .where(trial_ends_at: Time.current..7.days.from_now)
          .count
      }
    end

    def render_model_errors(record)
      render_json({
        error: "validation_failed",
        message: record.errors.full_messages.to_sentence,
        errors: record.errors.full_messages
      }, status: :unprocessable_entity)
    end
end
