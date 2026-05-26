require 'factory_bot'
Dir[Rails.root.join('spec/support/**/*.rb')].each { |f| require f }

class SeedData
  include FactoryBot::Syntax::Methods

  # Seed 6 of each member type (indices 0-5). Keeps the sandbox lean.
  MEMBER_COUNT = 6

  # Braintree sandbox test nonce — only used on first run.
  # Subsequent runs reuse existing Braintree customers via email lookup.
  SANDBOX_VISA_NONCE = "fake-valid-visa-nonce".freeze

  # PayPal and Venmo subscriptions skipped for now — basic_member0-5
  # cover the full subscription lifecycle for v1 E2E tests.
  # paypal_member0-5 are seeded as plain members without Braintree subscriptions.

  # Plan ID must match an existing plan in your Braintree sandbox account.
  SANDBOX_PLAN_ID = "membership-one-month-recurring".freeze

  def call
    create_permissions
    create_members
    create_board_members
    create_resource_managers
    create_rental_infrastructure   # Must run before create_rentals
    create_rentals
    create_payments
    create_group
    create_rejection_cards
    create_invoice_options
    create_subscriptions
  end

  private

  # ── Members ──────────────────────────────────────────────────────────────────

  def create_members
    create_expired_members
    create_admins
    MEMBER_COUNT.times do |n|
      create(:member,
        email:          "basic_member#{n}@test.com",
        firstname:      "Basic",
        lastname:       "Member#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
    MEMBER_COUNT.times do |n|
      create(:member,
        email:          "paypal_member#{n}@test.com",
        firstname:      "PayPal",
        lastname:       "Member#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
  end

  def create_expired_members
    MEMBER_COUNT.times do |n|
      create(:member, :expired,
        email:     "expired_member#{n}@test.com",
        firstname: "Expired",
        lastname:  "Member#{n}"
      )
    end
  end

  def create_admins
    MEMBER_COUNT.times do |n|
      create(:member, :admin,
        email:     "admin_member#{n}@test.com",
        firstname: "Admin",
        lastname:  "Member#{n}"
      )
    end
  end

  def create_board_members
    MEMBER_COUNT.times do |n|
      create(:member, :board_member,
        email:          "board_member#{n}@test.com",
        firstname:      "Board",
        lastname:       "Member#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
  end

  def create_resource_managers
    MEMBER_COUNT.times do |n|
      create(:member, :resource_manager,
        email:          "rm_member#{n}@test.com",
        firstname:      "Resource",
        lastname:       "Manager#{n}",
        expirationTime: (Time.now + 1.year).to_i * 1000
      )
    end
  end

  # ── Rental infrastructure ────────────────────────────────────────────────────
  # Mirrors db/seeds_rental_spots.rb — keep in sync if spot data changes.
  # Must run before create_rentals so RentalSpots exist to link against.

  def create_rental_infrastructure
    create_rental_invoice_options
    create_rental_types
    create_rental_spots
    puts "  [seed] Rental infrastructure: #{RentalType.count} types, #{RentalSpot.count} spots."
  end

  def create_rental_invoice_options
    [
      {
        name: "Monthly Tote Rental",
        description: "Tote rental subscription automatically renews every month on the day the subscription started.",
        amount: 15.0, quantity: 1, resource_class: "rental",
        plan_id: "rental-monthly-tote", operation: "renew=", disabled: false,
      },
      {
        name: "One Month Back Shop Shelf Rental",
        description: "Full shelf rental subscription automatically renews every month.",
        amount: 50.0, quantity: 1, resource_class: "rental",
        plan_id: "2023-rental-month-Back-Shelf", operation: "renew=", disabled: false,
      },
      {
        name: "One Month Half Back Shop Shelf Rental",
        description: "Half shelf rental subscription automatically renews every month.",
        amount: 30.0, quantity: 1, resource_class: "rental",
        plan_id: "2023-rental-month-Half-Back-Shelf", operation: "renew=", disabled: false,
      },
    ].each do |opt|
      next if InvoiceOption.where(plan_id: opt[:plan_id]).exists?
      InvoiceOption.create!(opt)
    end
  end

  def create_rental_types
    tote_opt       = InvoiceOption.find_by(plan_id: "rental-monthly-tote")
    half_shelf_opt = InvoiceOption.find_by(plan_id: "2023-rental-month-Half-Back-Shelf")
    full_shelf_opt = InvoiceOption.find_by(plan_id: "2023-rental-month-Back-Shelf")

    [
      { display_name: "Storage Tote",  invoice_option: tote_opt,       active: true },
      { display_name: "Full Shelf",    invoice_option: full_shelf_opt,  active: true },
      { display_name: "Half Shelf",    invoice_option: half_shelf_opt,  active: true },
      { display_name: "Parking Space", invoice_option: nil,             active: true },
      { display_name: "Plot",          invoice_option: nil,             active: true },
    ].each do |rt|
      next if RentalType.where(display_name: rt[:display_name]).exists?
      RentalType.create!(
        display_name:      rt[:display_name],
        active:            rt[:active],
        invoice_option_id: rt[:invoice_option]&.id&.to_s
      )
    end
  end

  def create_rental_spots
    tote_type       = RentalType.find_by(display_name: "Storage Tote")
    full_shelf_type = RentalType.find_by(display_name: "Full Shelf")
    half_shelf_type = RentalType.find_by(display_name: "Half Shelf")
    parking_type    = RentalType.find_by(display_name: "Parking Space")

    [
      { number: "LR-Tote-1", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-2", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-3", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-4", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-5", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "LR-Tote-6", location: "Locker Room", description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-1", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-2", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-3", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-4", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-5", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "BS-Tote-6", location: "Back Shop",   description: "Black Tote", rental_type: tote_type,       requires_approval: false, parent_number: nil },
      { number: "Shelf-1",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
      { number: "Shelf-2",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
      { number: "Shelf-3",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
      { number: "Shelf-4",   location: "Back Shop",   description: "Full Shelf", rental_type: full_shelf_type, requires_approval: false, parent_number: nil },
      { number: "Shelf-1a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-1" },
      { number: "Shelf-1b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-1" },
      { number: "Shelf-2a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-2" },
      { number: "Shelf-2b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-2" },
      { number: "Shelf-3a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-3" },
      { number: "Shelf-3b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-3" },
      { number: "Shelf-4a",  location: "Back Shop",   description: "Half Shelf (left)",  rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-4" },
      { number: "Shelf-4b",  location: "Back Shop",   description: "Half Shelf (right)", rental_type: half_shelf_type, requires_approval: false, parent_number: "Shelf-4" },
      { number: "Garage-1",  location: "Auto Bay",    description: "Auto Bay Overnight",     rental_type: parking_type, requires_approval: true, parent_number: nil },
      { number: "Parking-1", location: "Outside",     description: "Overnight Parking Spot", rental_type: parking_type, requires_approval: true, parent_number: nil },
    ].each do |s|
      next if RentalSpot.where(number: s[:number]).exists?
      RentalSpot.create!(
        number:            s[:number],
        location:          s[:location],
        description:       s[:description],
        rental_type_id:    s[:rental_type]&.id&.to_s,
        requires_approval: s[:requires_approval],
        active:            true,
        parent_number:     s[:parent_number]
      )
    end
  end

  # ── Rentals ──────────────────────────────────────────────────────────────────

  def create_rentals
    assignable_spots = RentalSpot.where(requires_approval: false, active: true).to_a
    members = Member.where(:email.nin => ["household_primary@test.com", "household_secondary@test.com"])
                    .limit(assignable_spots.length).to_a

    assignable_spots.each_with_index do |spot, i|
      member = members[i % members.length]
      next unless member
      Rental.create!(
        member:               member,
        number:               spot.number,
        rental_spot_id:       spot.id.to_s,
        description:          spot.description,
        expiration:           (Time.now + (i % 6 + 1).months).to_i * 1000,
        status:               "active",
        contract_signed_date: Date.today
      )
    end
    puts "  [seed] Created #{Rental.count} rentals linked to spots."
  end

  # ── Other ────────────────────────────────────────────────────────────────────

  def create_payments
    10.times { create(:payment) }
  end

  def create_group
    primary = create(:member,
      email:               "household_primary@test.com",
      firstname:           "Household",
      lastname:            "Primary",
      expirationTime:      (Time.now + 1.year).to_i * 1000,
      address_street:      "42 Elm Street",
      address_city:        "Manchester",
      address_state:       "NH",
      address_postal_code: "03101"
    )
    secondary = create(:member,
      email:               "household_secondary@test.com",
      firstname:           "Household",
      lastname:            "Secondary",
      expirationTime:      (Time.now + 6.months).to_i * 1000,
      address_street:      "42 Elm Street",
      address_city:        "Manchester",
      address_state:       "NH",
      address_postal_code: "03101"
    )
    Invoice.create!(
      member: primary, name: "Household Membership", description: "Household membership plan",
      amount: 85.0, quantity: 1, plan_id: "household-membership-one-month-recurring",
      resource_class: "member", resource_id: primary.id, operation: "renew=",
      due_date: Time.now + 1.month, settled_at: Time.now
    )
    Group.create!(groupName: primary.id.to_s, groupRep: primary.fullname, expiry: primary.expirationTime)
    primary.update!(groupName: primary.id.to_s)
    secondary.update!(groupName: primary.id.to_s, expirationTime: primary.expirationTime)
    puts "  [seed] Created household: #{primary.fullname} + #{secondary.fullname}"
  end

  def create_rejection_cards
    create(:rejection_card, uid: '0000', timeOf: Date.today)
    create(:rejection_card, uid: '0001', timeOf: Date.today)
    create(:rejection_card, uid: '0002', timeOf: Date.today)
  end

  def create_invoice_options
    create(:invoice_option, name: "One Month",    amount: 65.0,  id: "one-month",      plan_id: "membership-one-month-recurring",     discount_id: "monthly_membership_sso")
    create(:invoice_option, name: "Three Months", amount: 190.0, id: "three-months",   plan_id: "membership-three-month-recurring",   discount_id: "quarterly_membership_sso")
    create(:invoice_option, name: "One Year",     amount: 765.0, id: "one-year",       plan_id: "membership-twelve-month-recurring",  discount_id: "annual_membership_sso")
    create(:invoice_option,
      name:        "Household Monthly Membership Subscription",
      amount:      125.0, id: "household-one-month",
      plan_id:     "2024_household-membership-one-month-recurring",
      description: "Membership subscription for two adults in the same household, automatically renews every month on the day the subscription started"
    )
  end

  def create_permissions
    DefaultPermission.create(name: :billing,            enabled: true)
    DefaultPermission.create(name: :custom_billing,     enabled: false)
    DefaultPermission.create(name: :earned_membership,  enabled: true)
  end

  # ── Braintree subscriptions ──────────────────────────────────────────────────
  #
  # Creates/reuses subscriptions for basic_member0-5 (credit card via Visa nonce)
  # and paypal_member0-5 (PayPal billing agreement via PayPal nonce).
  #
  # db:db_reset wipes MongoDB but leaves Braintree sandbox intact.
  # On subsequent runs we search by email, reconnect existing customers/subscriptions
  # to the fresh MongoDB records, and skip creating new Braintree objects.
  #
  # Venmo: Venmo does not support recurring subscriptions in Braintree.
  # Venmo payment flows are covered by manual testing against existing members.

  def create_subscriptions
    gateway        = Service::BraintreeGateway.connect_gateway
    invoice_option = InvoiceOption.find("one-month")

    # All active roles are paying members and need a Braintree subscription.
    # Searches by email first — reuses existing Braintree customer/subscription
    # if found, so db:db_reset never creates duplicate billing.
    {
      "basic_member"  => "Basic",
      "admin_member"  => "Admin",
      "board_member"  => "Board",
      "rm_member"     => "Resource Manager",
    }.each do |prefix, label|
      MEMBER_COUNT.times do |n|
        member = Member.find_by(email: "#{prefix}#{n}@test.com")
        if member
          seed_subscription_for(member, invoice_option, gateway, SANDBOX_VISA_NONCE)
        else
          puts "  [seed] Warning: #{label} member #{n} not found, skipping subscription."
        end
      end
    end
  end

  def seed_subscription_for(member, invoice_option, gateway, nonce)
    results           = gateway.customer.search { |s| s.email.is(member.email) }
    existing_customer = results.first

    if existing_customer
      active_sub = find_active_subscription(existing_customer)

      if active_sub
        reconnect_member(member, existing_customer, active_sub, invoice_option)
        puts "  [seed] Reused subscription for #{member.fullname}: #{active_sub.id}"
        return
      end

      # Customer exists, subscription was cancelled — reuse payment method
      token = existing_customer.payment_methods.first&.token
      if token
        member.update!(customer_id: existing_customer.id)
        create_braintree_subscription(member, invoice_option, token, gateway)
        return
      end
    end

    # First run — create customer + payment method from nonce
    result = gateway.customer.create(
      first_name:           member.firstname,
      last_name:            member.lastname,
      email:                member.email,
      payment_method_nonce: nonce
    )
    unless result.success?
      puts "  [seed] Warning: Could not create Braintree customer for #{member.fullname}: #{result.message}"
      return
    end

    member.update!(customer_id: result.customer.id)
    create_braintree_subscription(member, invoice_option, result.customer.payment_methods.first.token, gateway)
  end

  def find_active_subscription(customer)
    customer.payment_methods.each do |pm|
      pm.subscriptions.each do |sub|
        return sub if sub.status == Braintree::Subscription::Status::Active
      end
    end
    nil
  end

  def reconnect_member(member, customer, subscription, invoice_option)
    member.update!(
      customer_id:     customer.id,
      subscription_id: subscription.id,
      subscription:    true,
      expirationTime:  subscription.paid_through_date.to_time.to_i * 1000
    )
    Invoice.create!(
      member:            member,
      name:              invoice_option.name,
      description:       invoice_option.description,
      amount:            invoice_option.amount,
      quantity:          invoice_option.quantity,
      plan_id:           invoice_option.plan_id,
      payment_method_id: subscription.payment_method_token,
      resource_class:    "member",
      resource_id:       member.id,
      operation:         invoice_option.operation,
      subscription_id:   subscription.id,
      due_date:          subscription.next_billing_date,
      settled_at:        Time.now
    )
  end

  def create_braintree_subscription(member, invoice_option, payment_method_token, gateway)
    invoice = Invoice.create!(
      member:            member,
      name:              invoice_option.name,
      description:       invoice_option.description,
      amount:            invoice_option.amount,
      quantity:          invoice_option.quantity,
      plan_id:           invoice_option.plan_id,
      payment_method_id: payment_method_token,
      resource_class:    "member",
      resource_id:       member.id,
      operation:         invoice_option.operation,
      due_date:          Time.now + 1.month
    )
    subscription_id = invoice.generate_subscription_id
    result = gateway.subscription.create(
      payment_method_token: payment_method_token,
      plan_id:              SANDBOX_PLAN_ID,
      id:                   subscription_id
    )
    unless result.success?
      puts "  [seed] Warning: Could not create subscription for #{member.fullname}: #{result.message}"
      return
    end
    member.update!(
      subscription_id: subscription_id,
      subscription:    true,
      expirationTime:  (Time.now + invoice_option.quantity.months).to_i * 1000
    )
    invoice.update!(subscription_id: subscription_id, settled_at: Time.now)
    puts "  [seed] Created subscription for #{member.fullname}: #{subscription_id}"
  end
end
