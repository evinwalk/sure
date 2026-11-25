require "test_helper"

class Assistant::Function::GetCashFlowForecastTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @family.recurring_transactions.destroy_all
    @account = accounts(:depository)
  end

  test "is hidden without preview features and listed with them" do
    assert_not_includes Assistant.function_classes(@user), Assistant::Function::GetCashFlowForecast

    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))

    assert_includes Assistant.function_classes(@user), Assistant::Function::GetCashFlowForecast
  end

  test "returns the engine's result" do
    due = Date.current + 3
    @family.recurring_transactions.create!(
      name: "Rent", account: @account, amount: 500, currency: "USD", bill_type: "bill", manual: true,
      expected_day_of_month: due.day, anchor_date: due,
      last_occurrence_date: due, next_expected_date: due, status: "active"
    )

    result = call_tool("account_id" => @account.id, "days" => 10)
    expected = Account::CashFlowForecast.new(@account, user: @user, through: Date.current + 10).call

    assert_equal expected.starting_balance.format, result[:starting_balance]
    assert_equal expected.ending_balance.format, result[:ending_balance]
    assert_equal expected.low_point.balance.format, result[:low_point][:balance]
    assert_equal expected.horizon.iso8601, result[:horizon]
    assert_equal "Rent", result[:days].sole[:items].sole[:name]
  end

  test "refuses an account the user cannot read" do
    assert_raises(ActiveRecord::RecordNotFound) do
      call_tool("account_id" => accounts(:connected).id, "days" => 10, "user" => users(:family_member))
    end
  end

  test "refuses a malformed account id" do
    assert_equal "account_id is not a valid id", call_tool("account_id" => "nope")[:error]
  end

  private
    def call_tool(params)
      Assistant::Function::GetCashFlowForecast.new(params.delete("user") || @user).call(params)
    end
end
