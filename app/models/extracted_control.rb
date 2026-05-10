class ExtractedControl
  attr_reader :control_id, :control_text

  def initialize(control_id:, control_text:)
    @control_id = control_id
    @control_text = control_text
  end

  def to_h
    {
      control_id: control_id,
      control_text: control_text
    }
  end
end
