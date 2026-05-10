class SourceControl
  attr_reader :normalised_control_text, :control_ids

  def initialize(normalised_control_text:, control_ids:)
    @normalised_control_text = normalised_control_text
    @control_ids = control_ids
  end

  def to_h
    {
      normalised_control_text: normalised_control_text,
      control_ids: control_ids
    }
  end
end
