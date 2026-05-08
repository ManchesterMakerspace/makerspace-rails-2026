class MembersController < AuthenticationController
    include FastQuery::MongoidQuery
    before_action :set_member, only: [:show, :update]

    def index
      base_query = Member.includes(:access_cards).includes(:earned_membership)

      if is_admin? || is_resource_manager?
        # Admins and Resource Managers can see all members,
        # filtered to current members only when requested
        if to_bool(search_params[:current_members])
          search = base_query.where({
            :$or => [
              { :expirationTime.gte => ((Time.now + 3.days).strftime('%s').to_i * 1000) },
              { expirationTime: nil }
            ]
          })
        else
          search = Mongoid::Criteria.new(base_query)
        end
      else
        # Regular members can only see themselves
        search = base_query.where(id: current_member.id)
      end

      @members = query_resource(search)
      return render_with_total_items(@members, { each_serializer: MemberSummarySerializer, adapter: :attributes })
    end

    def show
      render json: @member, serializer: MemberSerializer, adapter: :attributes and return
    end

    def update
      # Non admins can only update themselves
      raise Error::Forbidden.new unless @member.id == current_member.id

      if signature_params[:signature]
        encoded_signature = signature_params[:signature].split(",")[1]
        DocumentUploadJob.perform_later(encoded_signature, "member_contract", @member.id.as_json)
        @member.update_attributes!(member_contract_signed_date: Date.today)
      else
        @member.update_attributes!(member_params)
      end

      render json: @member, adapter: :attributes and return
    end

    private
    def set_member
      @member = Member.find(params[:id])
      raise ::Mongoid::Errors::DocumentNotFound.new(Member, { id: params[:id] }) if @member.nil?
    end

    def signature_params
      params.permit(:signature)
    end

    def member_params
      params.permit(:firstname, :lastname, :email, :phone, :silence_emails, address: [:street, :unit, :city, :state, :postal_code])
    end

    def search_params
      params.permit(:current_members, :format, :member, :page_num, :order_by, :order, :search)
    end
end
