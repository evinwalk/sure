require "test_helper"

class Account::CashFlowForecastTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    travel_to Date.new(2026, 12, 10)
    @family = families(:dylan_family)
    @user = users(:family_admin)
    @account = accounts(:depository)
    @family.recurring_transactions.destroy_all
    @account.update_columns(balance: 1000)
  end

  test "biweekly income adds on each payday and nets with a bill on the same day" do
    create_series(name: "Paycheck", amount: -2000, due: today + 2, preset: "biweekly", income: true)
    create_series(name: "Palisade", amount: 545, due: today + 2, preset: "biweekly")

    forecast = forecast(through: today + 30)

    paydays = [ today + 2, today + 16, today + 30 ]
    assert_equal paydays, forecast.days.select { |day| day.inflow.positive? }.map(&:date)
    payday = day(forecast, today + 2)
    assert_equal usd(2000), payday.inflow
    assert_equal usd(545), payday.outflow
    assert_equal usd(2455), payday.balance
    assert_equal usd(1000 + 3 * 1455), forecast.ending_balance
  end

  test "a semimonthly bill subtracts on both of its days" do
    create_series(name: "Card", amount: 100, due: Date.new(2026, 12, 15), preset: "semimonthly",
                  day_of_month: 1, second_day_of_month: 15)

    forecast = forecast(through: Date.new(2027, 1, 20))

    assert_equal [ Date.new(2026, 12, 15), Date.new(2027, 1, 1), Date.new(2027, 1, 15) ],
                 forecast.days.select { |day| day.outflow.positive? }.map(&:date)
    assert_equal usd(700), forecast.ending_balance
  end

  test "a transfer from another account adds to this one" do
    create_series(name: "Top-up", amount: 300, due: today + 5, account: accounts(:connected),
                  destination: @account)

    assert_equal usd(300), day(forecast(through: today + 10), today + 5).inflow
  end

  test "a snoozed bill lands on its snoozed date" do
    rent = create_series(name: "Rent", amount: 400, due: today + 3)
    rent.recurring_occurrences.open_status.order(:due_on).first.snooze!(today + 6)

    forecast = forecast(through: today + 10)

    assert day(forecast, today + 3).outflow.zero?
    assert_equal usd(400), day(forecast, today + 6).outflow
  end

  test "a partly paid bill counts only what remains" do
    rent = create_series(name: "Rent", amount: 1000, due: today + 4)
    RecurringTransaction::Allocator.new(rent.recurring_occurrences.order(:due_on).first).allocate!(amount: "400")

    assert_equal usd(600), day(forecast(through: today + 10), today + 4).outflow
  end

  test "an overdue bill in its grace window lands today; one past it is reported, not counted" do
    create_series(name: "Power", amount: 120, due: today - 2)
    create_series(name: "Water", amount: 64, due: today - 10)

    forecast = forecast(through: today + 10)

    assert_equal [ "Power" ], day(forecast, today).items.map(&:name)
    assert_equal usd(880), day(forecast, today).balance
    assert_equal [ "Water" ], forecast.assumptions[:past_grace]
  end

  test "a scheduled entry counts on its date unless it already paid an occurrence" do
    create_transaction(account: @account, name: "Car repair", date: today + 7, amount: 250)
    insurance = create_series(name: "Insurance", amount: 90, due: today + 8)
    paid_early = create_transaction(account: @account, name: "Insurance", date: today + 8, amount: 90)
    RecurringTransaction::Allocator.new(insurance.recurring_occurrences.order(:due_on).first).allocate!(entry: paid_early)

    forecast = forecast(through: today + 10)

    assert_equal usd(250), day(forecast, today + 7).outflow
    assert day(forecast, today + 8).outflow.zero?, "the payment and its bill are one outflow, already settled"
    assert_equal usd(750), forecast.ending_balance
  end

  test "the allowance is booked the day after each payday, only when set" do
    create_series(name: "Paycheck", amount: -2000, due: today + 2, preset: "biweekly", income: true)

    with = forecast(through: today + 20, allowance: 500)
    without = forecast(through: today + 20)

    assert_equal [ today + 3, today + 17 ], with.days.select { |day| day.outflow.positive? }.map(&:date)
    assert_equal usd(500), day(with, today + 3).outflow
    assert_equal usd(500), with.assumptions[:allowance]
    assert without.days.all? { |day| day.outflow.zero? }
  end

  test "the low point lands on the mortgage date, after payday and card payments" do
    create_series(name: "Paycheck", amount: -2500, due: Date.new(2026, 12, 25), income: true)
    create_series(name: "Cards", amount: 1200, due: Date.new(2026, 12, 27))
    create_series(name: "Mortgage", amount: 3327.96, due: Date.new(2027, 1, 1))

    forecast = forecast(through: Date.new(2027, 1, 20))

    assert_equal Date.new(2027, 1, 1), forecast.low_point.date
    assert_equal usd(BigDecimal("-1027.96")), forecast.low_point.balance
  end

  test "dates below the cushion are listed" do
    create_series(name: "Rent", amount: 800, due: today + 5)
    create_series(name: "Paycheck", amount: -2000, due: today + 10, income: true)

    assert_equal ((today + 5)..(today + 9)).to_a, forecast(through: today + 15, cushion: 500).below_cushion
    assert_empty forecast(through: today + 15).below_cushion, "with no cushion only a negative balance is flagged"
  end

  test "the horizon stops where occurrences stop being materialized" do
    forecast = forecast(through: today + 200)

    assert_equal today + RecurringTransaction::OccurrenceGenerator::HORIZON_DAYS, forecast.horizon
    assert_equal 91, forecast.days.size
  end

  test "only deposit accounts can be forecast" do
    assert_raises(ArgumentError) { Account::CashFlowForecast.new(accounts(:credit_card), user: @user) }
  end

  private
    def today
      Date.current
    end

    def usd(amount)
      Money.new(amount, "USD")
    end

    def day(forecast, date)
      forecast.days.find { |day| day.date == date }
    end

    def forecast(**options)
      Account::CashFlowForecast.new(@account, user: @user, **options).call
    end

    def create_series(name:, amount:, due:, preset: "monthly", income: false, account: @account, destination: nil, **preset_options)
      series = @family.recurring_transactions.create!(
        name: name,
        account: account,
        destination_account: destination,
        amount: amount,
        currency: "USD",
        bill_type: income ? "income" : "bill",
        expected_day_of_month: due.day,
        anchor_date: due,
        last_occurrence_date: due,
        next_expected_date: due,
        status: "active",
        manual: true
      )

      if preset != "monthly"
        RecurringTransaction::FrequencyPreset.apply(series, preset: preset, weekday: due.wday, **preset_options)
        series.save!
      end

      series
    end
end
