# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the rails db:seed command (or created alongside the database with db:setup).
#
# Examples:
#
#   movies = Movie.create([{ name: 'Star Wars' }, { name: 'Lord of the Rings' }])
#   Character.create(name: 'Luke', movie: movies.first)

company = Company.create!(name: 'New Co')

5.times do
  shipment = Shipment.create(
    company_id: company.id,
    destination_country: Faker::Address.country_code,
    origin_country: Faker::Address.country_code,
    tracking_number: %w(UM111116399USA UM459056399US).sample,
    slug: 'usps'
  )

  20.times do
    shipment.shipment_items.create(
      description: %w(iPhone iPad Watch iMac MacBook Mouse Keyboard).sample,
      weight: (1..5).to_a.sample,
      shipment_id: shipment.id
    )
  end

  shipment.save
end
