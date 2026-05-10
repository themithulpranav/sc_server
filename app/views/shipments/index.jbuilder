json.array! @shipments do |shipment|
  json.company_name         shipment.company.name
  json.origin_country       shipment.origin_country
  json.destination_country  shipment.destination_country
  json.tracking_number      shipment.tracking_number

  json.items shipment.shipment_items do |item|
    json.description        item.description
    json.weight             item.weight
  end
end
