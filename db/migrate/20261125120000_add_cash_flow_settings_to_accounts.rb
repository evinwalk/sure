class AddCashFlowSettingsToAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :accounts, :cash_flow_settings, :jsonb, default: {}, null: false
  end
end
