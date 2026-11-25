# A day-by-day projected balance for one deposit account: today's balance
# walked forward through the account's open bill, income and transfer
# occurrences and its scheduled entries, with the low point called out.
# Read-only; nothing here writes.
class Account::CashFlowForecast
  Item = Data.define(:date, :name, :amount, :source)
  Day = Data.define(:date, :inflow, :outflow, :balance, :items)
  LowPoint = Data.define(:date, :balance)
  Result = Data.define(:starting_balance, :days, :low_point, :below_cushion, :ending_balance, :horizon, :assumptions)

  attr_reader :account, :user, :through, :cushion, :allowance

  def initialize(account, user:, through: Date.current + 60, cushion: 0, allowance: 0)
    raise ArgumentError, "cash-flow forecasts cover depository accounts only" unless account.accountable_type == "Depository"

    @account = account
    @user = user
    # Occurrences are materialized no further, so a later date would read as
    # a quiet stretch with no bills in it.
    @through = [ through, Date.current + RecurringTransaction::OccurrenceGenerator::HORIZON_DAYS ].min
    @cushion = Money.new(cushion, account.currency)
    @allowance = Money.new(allowance, account.currency)
    @unconvertible = []
    @past_grace = []
  end

  def call
    by_date = (occurrence_items + entry_items + allowance_items).group_by(&:date)
    zero = Money.new(0, account.currency)
    balance = account.balance_money

    days = (Date.current..through).map do |date|
      items = by_date.fetch(date, [])
      inflow = items.select { |item| item.amount.positive? }.sum(zero, &:amount)
      outflow = -items.select { |item| item.amount.negative? }.sum(zero, &:amount)
      balance = balance + inflow - outflow
      Day.new(date:, inflow:, outflow:, balance:, items:)
    end

    low = days.min_by(&:balance)

    Result.new(
      starting_balance: account.balance_money,
      days: days,
      low_point: LowPoint.new(date: low.date, balance: low.balance),
      below_cushion: days.select { |day| day.balance < cushion }.map(&:date),
      ending_balance: days.last.balance,
      horizon: through,
      assumptions: {
        cushion: cushion,
        allowance: allowance,
        # Left out of the balance and named here, never folded in as zero.
        unconvertible: @unconvertible,
        # Past their grace window an unpaid bill is more likely paid but
        # unmatched than still coming, so counting it could double it.
        past_grace: @past_grace
      }
    )
  end

  private
    def occurrence_items
      @occurrence_items ||= occurrences.filter_map do |occurrence|
        series = occurrence.recurring_transaction
        date = occurrence.effective_due_on

        if date < Date.current
          if occurrence.derived_state == :overdue
            @past_grace << series.display_name
            next
          end
          # Late but inside its grace window: still expected to clear.
          date = Date.current
        end

        next unless occurrence.remaining_amount.positive?

        money = to_account_currency(occurrence.remaining_amount_money, series.display_name)
        next if money.nil?

        # Amounts are stored positive; the series says which way the money moves.
        inflow = series.destination_account_id == account.id || series.amount.negative?
        Item.new(date: date, name: series.display_name, amount: inflow ? money : -money, source: occurrence)
      end
    end

    def occurrences
      RecurringOccurrence.open_status
                         .joins(:recurring_transaction)
                         .where(recurring_transactions: { family_id: account.family_id, status: :active })
                         .merge(
                           RecurringTransaction.where(account_id: account.id)
                                               .or(RecurringTransaction.where(destination_account_id: account.id))
                         )
                         .merge(RecurringTransaction.accessible_by(user))
                         .where("#{RecurringOccurrence::EFFECTIVE_DUE_ON_SQL} <= ?", through)
                         .includes(:recurring_transaction)
                         .to_a
                         .tap { |rows| RecurringOccurrence.preload_confirmed_allocated(rows) }
    end

    # An entry already applied to an occurrence has reduced its remaining
    # amount, so counting the entry too would count the payment twice.
    def entry_items
      account.entries.excluding_pending.excluding_split_parents
             .where(entryable_type: %w[Transaction Trade])
             .where(date: (Date.current + 1)..through)
             .where.not(id: RecurringAllocation.confirmed.where.not(entry_id: nil).select(:entry_id))
             .includes(:entryable)
             .filter_map do |entry|
               amount = account.convert_scheduled_entry_amount(entry)
               amount && Item.new(date: entry.date, name: entry.name, amount: Money.new(amount, account.currency), source: entry)
             end
    end

    # Day-to-day spending no bill represents, booked as one lump the day after
    # each declared payday into this account.
    def allowance_items
      return [] unless allowance.positive?

      occurrence_items.filter_map { |item| item.date + 1 if payday?(item) }
                      .uniq
                      .select { |date| date <= through }
                      .map { |date| Item.new(date: date, name: nil, amount: -allowance, source: :allowance) }
    end

    def payday?(item)
      series = item.source.recurring_transaction
      series.typed_income? && series.manual? && series.account_id == account.id
    end

    def to_account_currency(money, name)
      money.exchange_to(account.currency)
    rescue Money::ConversionError
      @unconvertible << name
      nil
    end
end
