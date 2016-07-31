class AddPhoneToCASinoUsers < ActiveRecord::Migration
  def change
    add_column :casino_users, :phone, :string
  end
end
