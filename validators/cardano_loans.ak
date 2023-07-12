use aiken/bytearray
use aiken/dict.{Dict, has_key}
use aiken/hash.{Blake2b_224, Hash}
use aiken/interval.{Finite, NegativeInfinity, PositiveInfinity}
use aiken/list.{has}
use aiken/math/rational.{Rational}
use aiken/time.{PosixTime}
use aiken/transaction.{
  InlineDatum, Input, Mint, Output, ScriptContext, Spend, Transaction,
  ValidityRange,
}
use aiken/transaction/credential.{
  Address, Inline, Script, ScriptCredential, StakeCredential, VerificationKey,
  VerificationKeyCredential,
}
use aiken/transaction/value.{AssetName, PolicyId, Value}

// Ratio is used in the datum as a placeholder for the opaque type Rational
type Ratio {
  numerator: Int,
  denominator: Int,
}

type LoanDatum {
  AskDatum {
    loan_beacon: PolicyId,
    borrower_id: AssetName,
    loan_asset: (PolicyId, AssetName),
    principle: Int,
    term: PosixTime,
    collateral: List<(PolicyId, AssetName)>,
  }
  OfferDatum {
    loan_beacon: PolicyId,
    lender_id: AssetName,
    loan_asset: (PolicyId, AssetName),
    principle: Int,
    term: PosixTime,
    interest: Ratio,
    collateralization: List<((PolicyId, AssetName), Ratio)>,
  }
  ActiveDatum {
    loan_beacon: PolicyId,
    lender_id: AssetName,
    borrower_id: AssetName,
    loan_asset: (PolicyId, AssetName),
    principle: Int,
    term: PosixTime,
    interest: Ratio,
    collateralization: List<((PolicyId, AssetName), Ratio)>,
    expiration_slot: PosixTime,
    balance_owed: Ratio,
  }
}

type LoanRedeemer {
  CloseAsk
  CloseOffer
  AcceptOffer
  RepayLoan
  Claim
}

type BeaconRedeemer {
  MintAskToken(Hash<Blake2b_224, VerificationKey>)
  MintOfferToken(Hash<Blake2b_224, VerificationKey>)
  MintActiveToken(
    Hash<Blake2b_224, VerificationKey>,
    Hash<Blake2b_224, VerificationKey>,
  )
  BurnBeaconToken
}

type AppName =
  ByteArray

validator {
  fn loan(
    datum: LoanDatum,
    redeemer: LoanRedeemer,
    context: ScriptContext,
  ) -> Bool {
    let ScriptContext { transaction, purpose } = context
    expect Spend(own_output_ref) = purpose
    let Transaction {
      inputs,
      outputs,
      mint,
      withdrawals,
      validity_range,
      extra_signatories,
      ..
    } = transaction
    let mint = value.from_minted_value(mint)
    expect Some(Input(_, Output(i_addr, i_val, ..))) =
      transaction.find_input(inputs, own_output_ref)
    when redeemer is {
      CloseAsk -> {
        expect AskDatum { loan_beacon, .. } = datum
        expect True =
          staking_cred_approves(i_addr, extra_signatories, withdrawals)
        // Ask beacons must be burned
        all_beacons_burned(inputs, mint, loan_beacon, "Ask")
      }
      CloseOffer -> {
        expect OfferDatum { loan_beacon, lender_id, .. } = datum
        // Lender has custody if Offer beacon is present
        if value.quantity_of(i_val, loan_beacon, "Offer") == 1 {
          // Lender must sign
          expect True = list.has(extra_signatories, lender_id)
          // Ask beacons must be burned
          expect True = all_beacons_burned(inputs, mint, loan_beacon, "Offer")
          // Lender IDs must be burned
          all_beacons_burned(inputs, mint, loan_beacon, lender_id)
        } else {
          // utxo is invalid without Offer beacon, address owner has custody
          staking_cred_approves(i_addr, extra_signatories, withdrawals)
        }
      }
      AcceptOffer -> {
        expect True =
          staking_cred_approves(i_addr, extra_signatories, withdrawals)
        // Must be exactly 2 inputs from this address, one Ask and one Offer
        let (ask_val, ask_datum, offer_val, offer_datum) =
          ask_and_offer_data(inputs, i_addr)
        // There must be exactly one output to script address
        expect [Output(_, o_val, InlineDatum(o_datum), _)] =
          list.filter(outputs, fn(output) { output.address == i_addr })
        let loan_beacon =
          when datum is {
            AskDatum { loan_beacon, .. } -> loan_beacon
            OfferDatum { loan_beacon, .. } -> loan_beacon
            _other -> error @"Wrong datum type"
          }
        // Ask beacon must be with Ask datum
        expect True = value.quantity_of(ask_val, loan_beacon, "Ask") == 1
        // Offer beacon must be with Offer datum
        expect True = value.quantity_of(offer_val, loan_beacon, "Offer") == 1
        // Input datums must agree
        expect True = datums_agree(ask_datum, offer_datum)
        // Inputs must only have the Ask And Offer beacons
        expect True = no_other_input_beacons(inputs, loan_beacon)
        expect active_datum: LoanDatum = o_datum
        // Active datum must agree with Ask and Offer datums
        expect True =
          validity_range
            |> start_time()
            |> valid_active_datum(active_datum, ask_datum, offer_datum, _)
        expect OfferDatum { collateralization, principle, .. } = offer_datum
        // There must be enough collateral to meet the loan principle
        expect True =
          normalize_collateral(collateralization, o_val)
            |> rational.compare_with(>=, rational.from_int(principle))
        // The Active beacon must be minted to this address
        list.and(
          [
            value.quantity_of(mint, loan_beacon, "Active") == 1,
            value.quantity_of(o_val, loan_beacon, "Active") == 1,
          ],
        )
      }
      RepayLoan -> {
        expect ActiveDatum {
          loan_beacon,
          lender_id,
          borrower_id,
          loan_asset,
          principle,
          term,
          interest,
          collateralization,
          expiration_slot,
          balance_owed,
        } = datum
        expect True =
          staking_cred_approves(i_addr, extra_signatories, withdrawals)
        if value.quantity_of(i_val, loan_beacon, "Active") == 1 {
          // There must be exactly one output to script address
          expect [Output(_, o_val, InlineDatum(o_datum), _)] =
            list.filter(outputs, fn(output) { output.address == i_addr })
          // Net difference of assets at script
          let addr_diff =
            i_val
              |> value.negate()
              |> value.merge(o_val)
          let repaid_amount =
            addr_diff
              |> value.quantity_of(loan_asset.1st, loan_asset.2nd)
              |> rational.from_int()
          let remaining =
            balance_owed
              |> to_rational()
              |> rational.sub(repaid_amount)
              |> rational.reduce()
          // New datum must match old datum but with updated balance
          let expected_datum =
            ActiveDatum {
              loan_beacon,
              lender_id,
              borrower_id,
              loan_asset,
              principle,
              term,
              interest,
              collateralization,
              expiration_slot,
              balance_owed: Ratio(
                rational.numerator(remaining),
                rational.denominator(remaining),
              ),
            }
          expect new_state: LoanDatum = o_datum
          expect True = new_state == expected_datum
          // There must be a single input from this address
          expect True = list.length(all_addr_inputs(inputs, i_addr)) == 1
          // Loan must not be expired
          expect True = repayment_time(validity_range) <= expiration_slot
          // The Active beacon is the only phase beacon that can be present
          expect True = no_other_beacons(inputs, loan_beacon)
          // If new_outstanding is <= 0 then loan is fully repaid
          if rational.compare_with(remaining, <=, rational.zero()) {
            // All remaining collateral is unlocked
            // Borrower ID must be burned
            expect True =
              value.quantity_of(mint, loan_beacon, borrower_id) == -1
            // No other mints or burns
            expect True = list.length(value.flatten(mint)) == 1
            // Active beacon and lender ID must return to this address
            list.and(
              [
                value.quantity_of(o_val, loan_beacon, lender_id) == 1,
                value.quantity_of(o_val, loan_beacon, "Active") == 1,
              ],
            )
          } else {
            // Otherwise partial repayment
            // sum (collateral asset taken / relative value) * (1 + interest) <= loan asset repaid
            expect True =
              interest
                |> to_rational()
                |> rational.add(rational.from_int(1))
                |> rational.mul(normalize_collateral(collateralization, addr_diff))
                |> rational.negate()
                |> rational.compare_with(<=, repaid_amount)
            // Active beacon, borrower ID, and lender ID must be present
            let beacon_assets = value.tokens(o_val, loan_beacon)
            list.and(
              [
                dict.get(beacon_assets, lender_id) == Some(1),
                dict.get(beacon_assets, borrower_id) == Some(1),
                dict.get(beacon_assets, "Active") == Some(1),
              ],
            )
          }
        } else {
          True
        }
      }
      Claim -> {
        expect ActiveDatum {
          loan_beacon,
          lender_id,
          borrower_id,
          expiration_slot,
          balance_owed,
          ..
        } = datum
        // The Active beacon must be present
        expect True = value.quantity_of(i_val, loan_beacon, "Active") == 1
        // The Active beacon is the only phase beacon that can be present
        expect True = no_other_beacons(inputs, loan_beacon)
        let loan_expired = start_time(validity_range) > expiration_slot
        let loan_fully_repaid =
          balance_owed
            |> to_rational()
            |> rational.compare_with(<=, rational.zero())
        // The Loan must be expired or fully repaid
        expect True = loan_expired || loan_fully_repaid
        // The Active beacon must be burned
        expect True = value.quantity_of(mint, loan_beacon, "Active") == -1
        // The lender ID must be burned
        expect True = value.quantity_of(mint, loan_beacon, lender_id) == -1
        // The Lender must sign
        expect True = list.has(extra_signatories, lender_id)
        // If the borrower ID is still present
        if value.quantity_of(i_val, loan_beacon, borrower_id) == 1 {
          // The borrower ID must be burned
          expect True = value.quantity_of(mint, loan_beacon, borrower_id) == -1
          // No other mints
          list.length(value.flatten(mint)) == 3
        } else {
          // No other mints
          list.length(value.flatten(mint)) == 2
        }
      }
    }
  }
}

fn staking_cred_approves(
  addr: Address,
  extra_signatories: List<Hash<Blake2b_224, VerificationKey>>,
  withdrawals: Dict<StakeCredential, Int>,
) -> Bool {
  when addr.stake_credential is {
    None -> True
    Some(ref_cred) ->
      when ref_cred is {
        Inline(cred) ->
          when cred is {
            VerificationKeyCredential(pkh) -> has(extra_signatories, pkh)
            ScriptCredential(_) -> has_key(withdrawals, ref_cred)
          }
        _other -> error @"Wrong kind of staking credential"
      }
  }
}

// Get all quantities of all assets for a given policy across all inputs
fn all_values_of_policy(
  inputs: List<Input>,
  policy: PolicyId,
) -> Dict<AssetName, Int> {
  list.foldr(
    inputs,
    dict.new(),
    fn(input, total) {
      dict.union_with(
        value.tokens(input.output.value, policy),
        total,
        fn(_k, v1, v2) { Some(v1 + v2) },
        bytearray.compare,
      )
    },
  )
}

// Prevent double satisfaction for AcceptOffer
fn no_other_input_beacons(inputs: List<Input>, policy: PolicyId) {
  let all_beacons = all_values_of_policy(inputs, policy)
  list.and(
    [
      dict.get(all_beacons, "Ask") == Some(1),
      dict.get(all_beacons, "Offer") == Some(1),
      dict.get(all_beacons, "Active") == None,
    ],
  )
}

// This is only used with the RepayLoan and Claim. This ensures all loans are treated separately.
fn no_other_beacons(inputs: List<Input>, policy: PolicyId) -> Bool {
  let all_beacons = all_values_of_policy(inputs, policy)
  list.and(
    [
      dict.get(all_beacons, "Ask") == None,
      dict.get(all_beacons, "Offer") == None,
      dict.get(all_beacons, "Active") == Some(1),
    ],
  )
}

// Ensures all of the specified asset found in the inputs is burned
fn all_beacons_burned(
  inputs: List<Input>,
  mint: Value,
  policy: PolicyId,
  asset: AssetName,
) -> Bool {
  // Total amount of an asset across all inputs
  let asset_input_value =
    list.foldr(
      inputs,
      0,
      fn(input, total) {
        value.quantity_of(input.output.value, policy, asset) + total
      },
    )
  asset_input_value == -value.quantity_of(mint, policy, asset)
}

// Get all inputs from an address
fn all_addr_inputs(inputs: List<Input>, addr: Address) -> List<Input> {
  list.filter(inputs, fn(input) { input.output.address == addr })
}

// Ensures there are exactly 2 inputs from the script, 1 Ask, 1 Offer
// and returns the values with the datums
fn ask_and_offer_data(
  inputs: List<Input>,
  addr: Address,
) -> (Value, LoanDatum, Value, LoanDatum) {
  // There must be exactly two inputs from this address
  expect [
    Input(_, Output(_, x_val, InlineDatum(x_dat), _)),
    Input(_, Output(_, y_val, InlineDatum(y_dat), _)),
  ] = all_addr_inputs(inputs, addr)
  expect x_loan: LoanDatum = x_dat
  expect y_loan: LoanDatum = y_dat
  when (x_loan, y_loan) is {
    (AskDatum(..), OfferDatum(..)) -> (x_val, x_loan, y_val, y_loan)
    (OfferDatum(..), AskDatum(..)) -> (y_val, y_loan, x_val, x_loan)
    _other -> error @"Inputs are not the right phases"
  }
}

fn datums_agree(ask: LoanDatum, offer: LoanDatum) -> Bool {
  expect AskDatum {
    loan_beacon: ask_beacon,
    loan_asset: ask_asset,
    principle: ask_principle,
    term: ask_term,
    collateral: ask_collateral,
    ..
  } = ask
  expect OfferDatum {
    loan_beacon: offer_beacon,
    loan_asset: offer_asset,
    principle: offer_principle,
    term: offer_term,
    collateralization: offer_collateralization,
    ..
  } = offer
  list.and(
    [
      ask_beacon == offer_beacon,
      ask_asset == offer_asset,
      ask_principle == offer_principle,
      ask_term == offer_term,
      ask_collateral == list.map(offer_collateralization, fn(col) { col.1st }),
    ],
  )
}

// Configured for preprod
fn start_time(range: ValidityRange) -> PosixTime {
  when range.lower_bound.bound_type is {
    NegativeInfinity -> error @"Invalid-before not specified"
    Finite(t) -> ( t - 1655683200000 ) / 1000
    PositiveInfinity -> error @"Shouldn't be positive infinity"
  }
}

// Configured for preprod
fn repayment_time(range: ValidityRange) -> PosixTime {
  when range.upper_bound.bound_type is {
    PositiveInfinity -> error @"Invalid-hereafter not specified"
    Finite(t) -> ( t - 1655683200000 ) / 1000
    NegativeInfinity -> error @"Shouldn't be negative infinity"
  }
}

// Ensures the Active datum adheres to the respective Ask and Offer datums
fn valid_active_datum(
  active: LoanDatum,
  ask: LoanDatum,
  offer: LoanDatum,
  start_time: PosixTime,
) {
  expect AskDatum { loan_beacon, loan_asset, principle, term, borrower_id, .. } =
    ask
  expect OfferDatum { collateralization, lender_id, interest, .. } = offer
  expect ActiveDatum {
    loan_beacon: active_beacon,
    lender_id: active_lender,
    borrower_id: active_borrower,
    loan_asset: active_asset,
    principle: active_principle,
    term: active_term,
    collateralization: active_collateralization,
    interest: active_interest,
    expiration_slot: active_expiration,
    balance_owed: active_balance,
  } = active
  // The balance on the Active datum must be the principle * (1 + interest)
  let correct_balance =
    interest
      |> to_rational()
      |> rational.add(rational.from_int(1))
      |> rational.mul(rational.from_int(principle))
      |> rational.compare_with(==, to_rational(active_balance))
  list.and(
    [
      correct_balance,
      active_beacon == loan_beacon,
      active_lender == lender_id,
      active_borrower == borrower_id,
      active_asset == loan_asset,
      active_principle == principle,
      active_term == term,
      active_interest == interest,
      active_collateralization == collateralization,
      active_expiration == start_time + term,
    ],
  )
}

// Convert collateral to units of the asset being lent
fn normalize_collateral(
  collateralization: List<((PolicyId, AssetName), Ratio)>,
  collateral: Value,
) -> Rational {
  list.foldr(
    collateralization,
    rational.zero(),
    fn(col, total) {
      expect Some(loan_asset_per_col) =
        col.2nd
          |> to_rational()
          |> rational.reciprocal()
      value.quantity_of(collateral, col.1st.1st, col.1st.2nd)
        |> rational.from_int()
        |> rational.mul(loan_asset_per_col)
        |> rational.add(total)
    },
  )
}

validator(app_name: AppName, dapp_hash: Hash<Blake2b_224, Script>) {
  fn beacon_policy(redeemer: BeaconRedeemer, context: ScriptContext) -> Bool {
    let ScriptContext { transaction, purpose } = context
    let Transaction { outputs: outs, mint, extra_signatories, .. } = transaction
    expect Mint(policy) = purpose
    let beacon_mint =
      mint
        |> value.from_minted_value()
        |> value.tokens(policy)
        |> dict.to_list()
    when redeemer is {
      MintAskToken(pkh) -> {
        // Only one beacon can be minted and it must be the Ask beacon
        let one_beacon_minted = beacon_mint == [("Ask", 1)]
        let signed = list.has(extra_signatories, pkh)
        one_beacon_minted && ask_outputs_check(outs, pkh, policy, dapp_hash) && signed
      }
      MintOfferToken(pkh) -> {
        let mint_check = offer_mint_check(beacon_mint, pkh)
        let destination_check =
          offer_outputs_check(outs, pkh, policy, dapp_hash)
        let signed = list.has(transaction.extra_signatories, pkh)
        mint_check && destination_check && signed
      }
      MintActiveToken(b_pkh, l_pkh) -> {
        let mint_check = active_mint_check(beacon_mint, b_pkh)
        let destination_check =
          active_outputs_check(outs, b_pkh, l_pkh, policy, dapp_hash)
        mint_check && destination_check
      }
      BurnBeaconToken -> list.all(beacon_mint, fn(beacon) { beacon.2nd < 0 })?
    }
  }
}

// Check that only the Offer beacon and lender ID are minted
fn offer_mint_check(
  beacon_mint: List<(AssetName, Int)>,
  pkh: Hash<Blake2b_224, Script>,
) -> Bool {
  // Only the offer beacon and lender ID can be minted
  expect [(name1, amount1), (name2, amount2)] = beacon_mint
  if name1 == "Offer" {
    amount1 == 1 && name2 == pkh && amount2 == 1
  } else if name2 == "Offer" {
    amount2 == 1 && name1 == pkh && amount1 == 1
  } else {
    error @"Only the offer beacon and lender ID can be minted"
  }
}

// Offer and Ask must be burned while Active and borrower ID must be minted
fn active_mint_check(
  beacon_mint: List<(AssetName, Int)>,
  borrower_pkh: Hash<Blake2b_224, Script>,
) -> Bool {
  list.and(
    [
      list.length(beacon_mint) == 4,
      list.has(beacon_mint, ("Ask", -1)),
      list.has(beacon_mint, ("Offer", -1)),
      list.has(beacon_mint, ("Active", 1)),
      list.has(beacon_mint, (borrower_pkh, 1)),
    ],
  )
}

// Check that Ask beacon goes to the proper address and with an Ask datum
fn ask_outputs_check(
  outputs: List<Output>,
  pkh: Hash<Blake2b_224, Script>,
  policy: PolicyId,
  dapp_hash: Hash<Blake2b_224, Script>,
) -> Bool {
  list.foldl(
    outputs,
    True,
    fn(out, acc) {
      let Output { address: addr, value: val, datum: dat, .. } = out
      if value.quantity_of(val, policy, "Ask") == 1 {
        // Ask beacon must go to a dapp address using a staking pubkey
        expect Address(
          ScriptCredential(vh),
          Some(Inline(VerificationKeyCredential(pkh2))),
        ) = addr
        expect InlineDatum(inline) = dat
        expect datum: LoanDatum = inline
        // Ask beacon must be stored with an Ask datum
        expect AskDatum { .. } = datum
        // Beacon must be minted to the proper address
        let valid_destination = vh == dapp_hash
        acc && valid_destination && valid_ask_datum(pkh, datum, policy) && pkh == pkh2
      } else {
        acc
      }
    },
  )
}

fn offer_outputs_check(
  outputs: List<Output>,
  pkh: Hash<Blake2b_224, Script>,
  policy: PolicyId,
  dapp_hash: Hash<Blake2b_224, Script>,
) -> Bool {
  list.foldl(
    outputs,
    True,
    fn(out, acc) {
      let Output { address: addr, value: val, datum: dat, .. } = out
      if value.quantity_of(val, policy, "Offer") == 1 {
        // Offer token and lender ID must be stored in the same utxo
        expect True = value.quantity_of(val, policy, pkh) == 1
        // Offer beacon must go to a dapp address using a staking pubkey
        expect Address(
          ScriptCredential(vh),
          Some(Inline(VerificationKeyCredential(_))),
        ) = addr
        // Beacon must be minted to the proper address
        let valid_destination = vh == dapp_hash
        expect InlineDatum(inline) = dat
        expect datum: LoanDatum = inline
        // Offer beacon must be stored with Offer datum
        expect OfferDatum { loan_asset: (l_pol, l_asset), principle, .. } =
          datum
        // Requested loan amount must be met by collateral
        let principle_met =
          if l_pol == value.ada_policy_id && l_asset == value.ada_policy_id {
            value.lovelace_of(val) >= principle + 3000000
          } else {
            value.quantity_of(val, l_pol, l_asset) >= principle
          }
        acc && valid_destination && valid_offer_datum(pkh, datum, policy) && principle_met
      } else {
        acc
      }
    },
  )
}

fn active_outputs_check(
  outputs: List<Output>,
  borrower_pkh: Hash<Blake2b_224, Script>,
  lender_pkh: Hash<Blake2b_224, Script>,
  policy: PolicyId,
  dapp_hash: Hash<Blake2b_224, Script>,
) -> Bool {
  list.foldl(
    outputs,
    True,
    fn(out, acc) {
      let Output { address: addr, value: val, .. } = out
      if value.quantity_of(val, policy, "Active") == 1 {
        // Borrower ID must be stored with Active beacon
        expect True = value.quantity_of(val, policy, borrower_pkh) == 1
        // Lender ID must be stored with borrower ID and Active beacon
        expect True = value.quantity_of(val, policy, lender_pkh) == 1
        // Active token must go to the dapp address using the supplied staking pubkey
        expect Address(
          ScriptCredential(vh),
          Some(Inline(VerificationKeyCredential(pkh))),
        ) = addr
        // Beacon must be minted to the proper address
        let valid_destination = vh == dapp_hash
        acc && valid_destination && borrower_pkh == pkh
      } else {
        acc
      }
    },
  )
}

fn valid_ask_datum(
  pkh: Hash<Blake2b_224, Script>,
  ask: LoanDatum,
  policy: PolicyId,
) -> Bool {
  expect AskDatum { loan_beacon, borrower_id, principle, term, collateral, .. } =
    ask
  list.and(
    [
      loan_beacon == policy,
      borrower_id == pkh,
      principle > 0,
      term > 0,
      !list.is_empty(collateral),
    ],
  )
}

fn valid_offer_datum(
  pkh: Hash<Blake2b_224, Script>,
  offer: LoanDatum,
  policy: PolicyId,
) -> Bool {
  expect OfferDatum {
    loan_beacon,
    principle,
    term,
    interest,
    lender_id,
    collateralization,
    ..
  } = offer
  let interest_greater_than_0 =
    interest
      |> to_rational()
      |> rational.compare_with(>, rational.zero())
  let collateral_greater_than_0 =
    list.all(
      collateralization,
      fn(col) {
        col.2nd
          |> to_rational()
          |> rational.compare_with(>, rational.zero())
      },
    )
  list.and(
    [
      loan_beacon == policy,
      lender_id == pkh,
      principle > 0,
      term > 0,
      interest_greater_than_0,
      !list.is_empty(collateralization),
      collateral_greater_than_0,
    ],
  )
}

fn to_rational(ratio: Ratio) -> Rational {
  let Ratio(n, d) = ratio
  expect Some(r) = rational.new(n, d)
  r
}
