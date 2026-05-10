class CreateShipments < ActiveRecord::Migration[5.0]
  def change
    create_table :shipments do |t|
      t.references :company, foreign_key: true
      t.string :destination_country
      t.string :origin_country
      t.string :tracking_number
      t.string :slug

      t.timestamps
    end
  end
end
