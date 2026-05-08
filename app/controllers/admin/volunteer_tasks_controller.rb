# Admin::VolunteerTasksController
#
# Admin and Resource Managers can manage bounty tasks.
# Admins additionally can destroy tasks.
#
class Admin::VolunteerTasksController < AdminOrRmController
  before_action :find_task, only: [:update, :destroy, :complete, :cancel, :release, :reject_pending]

  # GET /api/admin/volunteer_tasks
  def index
    tasks = VolunteerTask.all.order_by(created_at: :desc)
    tasks = tasks.where(status: params[:status]) if params[:status].present?
    render json: tasks, each_serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_tasks
  def create
    task = VolunteerTask.new(task_params.merge(
      created_by_id: current_member.id,
      credit_value:  task_params[:credit_value]&.to_f || 1.0
    ))
    task.save!
    render json: task, serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # PUT /api/admin/volunteer_tasks/:id
  def update
    @task.update!(task_params)
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # POST /api/admin/volunteer_tasks/:id/complete
  # Verify a task as complete and issue the credit.
  def complete
    @task.complete!(current_member)
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot verify your own task completion' }, status: :forbidden
  end

  # POST /api/admin/volunteer_tasks/:id/release
  # Release a claimed task back to available when member never completed it.
  def release
    raise ::Error::Unprocessable.new unless params[:reason].present?
    @task.release!(current_member, params[:reason])
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot release your own claimed task' }, status: :forbidden
  end

  # POST /api/admin/volunteer_tasks/:id/reject_pending
  # Reject a pending task — member marked done but work not accepted.
  def reject_pending
    raise ::Error::Unprocessable.new unless params[:reason].present?
    @task.reject_pending!(current_member, params[:reason])
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  rescue Error::Forbidden
    render json: { error: 'You cannot reject your own task' }, status: :forbidden
  end

  # POST /api/admin/volunteer_tasks/:id/cancel
  def cancel
    @task.cancel!
    render json: @task, serializer: VolunteerTaskSerializer, adapter: :attributes
  end

  # DELETE /api/admin/volunteer_tasks/:id
  def destroy
    raise ::Error::Forbidden.new unless is_admin?
    @task.destroy
    render json: {}, status: :no_content
  end

  private

  def find_task
    @task = VolunteerTask.find(params[:id])
    raise ::Mongoid::Errors::DocumentNotFound.new(VolunteerTask, { id: params[:id] }) if @task.nil?
  end

  def task_params
    params.permit(:title, :description, :credit_value, :shop_id)
  end
end
