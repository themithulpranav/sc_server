class CreateShipmentItems < ActiveRecord::Migration[5.0]
  def change
    create_table :shipment_items do |t|
      t.string :description
      t.references :shipment, foreign_key: true
      t.integer :weight

      t.timestamps
    end
  end
end
