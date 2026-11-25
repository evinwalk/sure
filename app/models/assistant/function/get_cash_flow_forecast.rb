class Assistant::Function::GetCashFlowForecast < Assistant::Function
  include Assistant::Function::BillsSupport

  class << self
    def name
      "get_cash_flow_forecast"
    end

    def description
      <<~INSTRUCTIONS
        Project one checking or savings account's balance day by day from today through its
        open bills, declared income, incoming transfers and scheduled transactions, and report
        the lowest point and the dates the balance falls below a cushion.

        - low_point is the day the projected balance is lowest; below_cushion lists the dates
          under the cushion.
        - assumptions names what was left out: bills past their grace window (likely paid but
          unmatched) and amounts that could not be converted. Mention them rather than
          presenting the projection as complete.
        - The horizon is capped; when it is shorter than requested, say so.

        account_id must be the exact id returned by get_accounts. Depository accounts only.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "account_id" ],
      properties: {
        account_id: { type: "string", description: "The account's id, exactly as returned by get_accounts." },
        days: { type: "integer", minimum: 1, maximum: 90, description: "How many days ahead to project (default 60)." },
        cushion: { type: "number", minimum: 0, description: "Balance floor to flag days below (default 0)." },
        allowance: { type: "number", minimum: 0, description: "Day-to-day spending to book the day after each declared payday (default 0)." }
      }
    )
  end

  def call(params = {})
    return recurring_disabled_result if recurring_disabled?
    return { error: "account_id is not a valid id", hint: "Pass the exact id returned by get_accounts." } unless valid_uuid?(params["account_id"])

    account = user.accessible_accounts.visible.find(params["account_id"])
    unless account.accountable_type == "Depository"
      return { error: "Cash-flow forecasts cover checking and savings accounts only", hint: "Do not retry with this account." }
    end

    days = (Integer(params["days"].to_s, exception: false) || 60).clamp(1, 90)
    result = Account::CashFlowForecast.new(
      account, user: user, through: Date.current + days,
      cushion: params["cushion"].to_d, allowance: params["allowance"].to_d
    ).call

    serialize(result)
  end

  private
    def serialize(result)
      {
        account_currency: result.starting_balance.currency.iso_code,
        starting_balance: result.starting_balance.format,
        ending_balance: result.ending_balance.format,
        low_point: { date: result.low_point.date.iso8601, balance: result.low_point.balance.format },
        below_cushion: result.below_cushion.map(&:iso8601),
        horizon: result.horizon.iso8601,
        days: result.days.reject { |day| day.items.empty? }.map { |day| serialize_day(day) },
        assumptions: {
          cushion: result.assumptions[:cushion].format,
          allowance: result.assumptions[:allowance].format,
          unconvertible: result.assumptions[:unconvertible],
          past_grace: result.assumptions[:past_grace]
        }
      }
    end

    # Quiet days are left out; the low point and cushion dates already cover them.
    def serialize_day(day)
      {
        date: day.date.iso8601,
        balance: day.balance.format,
        items: day.items.map { |item| { name: item.name || "Allowance", amount: item.amount.format } }
      }
    end
end
