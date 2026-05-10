class Shipment < ApplicationRecord
  belongs_to :company
  has_many :shipment_items
end
