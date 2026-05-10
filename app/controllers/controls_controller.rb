class ControlsController < ApplicationController
  def process_request
    Rails.logger.info(
      "[ControlsController] process_request received: " \
      "source_control=#{params[:source_control]&.original_filename.inspect}, " \
      "trust_pdf_doc=#{params[:trust_pdf_doc]&.original_filename.inspect}, " \
      "trust_center_url=#{params[:trust_center_url].inspect}"
    )

    pdf = params[:trust_pdf_doc]
    url = params[:trust_center_url].presence

    if pdf.blank? && url.blank?
      Rails.logger.warn(
        "[ControlsController] missing both trust_pdf_doc and trust_center_url -> 400"
      )
      return render json: { error: "Provide at least one of trust_pdf_doc or trust_center_url" },
                    status: :bad_request
    end

    result = ControlService.new(
      source_control_csv: params.require(:source_control),
      trust_pdf_doc: pdf,
      trust_center_url: url
    ).call

    Rails.logger.info("[ControlsController] response: #{result.inspect}")

    render json: result, status: :ok
  end
end
