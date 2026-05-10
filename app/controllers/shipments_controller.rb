class ShipmentsController < ApplicationController
  def index
    @shipments = Shipment.all
    @shipments
  end
end
