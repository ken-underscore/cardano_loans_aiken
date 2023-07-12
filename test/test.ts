import {
    Emulator,
    fromText,
    getAddressDetails,
    Lucid,
    TxHash,
    PolicyId,
    Unit,
    Data
  } from "https://deno.land/x/lucid@0.10.4/mod.ts";
import { CardanoLoansBeaconPolicy as Beacon } from "../plutus.ts";
import { CardanoLoansLoan as Loan } from "../plutus.ts";

  // Basic end to end tests
  
  // Initialize Emulator
  const lucidInit = await Lucid.new(undefined, "Custom")
  const borrowerSeed = lucidInit.utils.generateSeedPhrase();
  const borrowerAddr = await lucidInit.selectWalletFromSeed(borrowerSeed).wallet.address();
  const lenderSeed = lucidInit.utils.generateSeedPhrase();
  const lenderAddr = await lucidInit.selectWalletFromSeed(lenderSeed).wallet.address();
  const cPolicy = "c0f8644a01a6bf5db02f4afe30d604975e63dd274f1098a1738e561d";
  const cAsset = "6c7563696431";
  const collateralAsset = cPolicy + cAsset
  const emulator = new Emulator([{ address: borrowerAddr, assets: { [collateralAsset]: 1000n, lovelace: 100000000n } }, { address: lenderAddr, assets: { lovelace: 1000000000n } }]);
  const startTime = 1655683200000;
  emulator.time = startTime; //configuring slot 0 like preprod env
  const lucid = await Lucid.new(emulator);

  // Create test config
  const startSlot = 0;
  const term = 10000;
  const { stakeCredential: bStakeCred } = getAddressDetails(borrowerAddr);
  const bStakeKeyHash = bStakeCred!.hash
  const { paymentCredential: lPaymentCred } = getAddressDetails(lenderAddr);
  const lPaymentKeyHash = lPaymentCred!.hash
  const mp = new Beacon();
  const policyId: PolicyId = lucid.utils.mintingPolicyToId(mp);
  const loan = new Loan();
  const askAsset: Unit = policyId + fromText("Ask");
  const offerAsset: Unit = policyId + fromText("Offer");
  const activeAsset: Unit = policyId + fromText("Active");
  const lenderAsset: Unit = policyId + lPaymentKeyHash
  const borrowerAsset: Unit = policyId + bStakeKeyHash
  const assetTuple: [string, string] = [cPolicy, cAsset];
  const loanAddr = lucid.utils.validatorToAddress(loan, bStakeCred)

  // Test CloseAsk
  await createAsk();
  emulator.awaitBlock(4);
  await closeAsk();
  emulator.awaitBlock(4);

  // Test CloseOffer
  await createOffer();
  emulator.awaitBlock(4);
  await closeOffer();
  emulator.awaitBlock(4);

  // Test basic loan happy path
  await createAsk();
  emulator.awaitBlock(4);
  await createOffer();
  emulator.awaitBlock(4);
  await acceptOffer();
  emulator.awaitBlock(4);
  await partialRepayment();
  emulator.awaitBlock(4);
  await fullRepayment();
  emulator.awaitBlock(4);
  await claim();

  async function createAsk(): Promise<TxHash> {
    lucid.selectWalletFromSeed(borrowerSeed)
    const redeemer = Data.to({
      MintAskToken: [bStakeKeyHash]
    }, Beacon.redeemer)
    const datum = Data.to({
      AskDatum: {
        loanBeacon: policyId,
        borrowerId: bStakeKeyHash,
        loanAsset: ["", ""],
        principle: 10000000n,
        term: BigInt(term),
        collateral: new Map([[cPolicy, cAsset]])
      }
    }, Loan.datum)

    const tx = await lucid
      .newTx()
      .addSigner(await lucid.wallet.address())
      .addSigner((await lucid.wallet.rewardAddress())!)
      .mintAssets( {[askAsset]: 1n}, redeemer)
      .attachMintingPolicy(mp)
      .payToContract(loanAddr, {
          inline: datum
      }, {[askAsset]: 1n, lovelace: 2000000n })
      .complete()

    console.log("Create Ask Fee: " + tx.fee)
    const signedTx = await tx.sign().complete();
    return signedTx.submit();
  }

  async function closeAsk(): Promise<TxHash> {
    lucid.selectWalletFromSeed(borrowerSeed);
    const closeAskRedeemer = Data.to("CloseAsk", Loan.redeemer);
    const burnRedeemer = Data.to("BurnBeaconToken", Beacon.redeemer);
    const utxos = await lucid.utxosAt(loanAddr);

    const tx = await lucid
      .newTx()
      .collectFrom(utxos, closeAskRedeemer)
      .addSigner((await lucid.wallet.rewardAddress())!)
      .mintAssets( {[askAsset]: -1n}, burnRedeemer)
      .attachMintingPolicy(mp)
      .attachSpendingValidator(loan)
      .complete();

    console.log("Close Ask Fee: " + tx.fee)
    const signedTx = await tx.sign().complete();
    return signedTx.submit();
  }
  
  async function createOffer(): Promise<TxHash> {
    lucid.selectWalletFromSeed(lenderSeed)
    const redeemer = Data.to({
        MintOfferToken: [lPaymentKeyHash]
    }, Beacon.redeemer)
    const datum = Data.to({
      OfferDatum: {
        loanBeacon: policyId,
        lenderId: lPaymentKeyHash,
        loanAsset: ["", ""],
        principle: 10000000n,
        term: BigInt(term),
        interest: { numerator: 1n, denominator: 20n},
        collateralization: new Map([[assetTuple, { numerator: 1n, denominator: 500000n}]])
      }
    }, Loan.datum);

    const tx = await lucid
      .newTx()
      .addSigner(await lucid.wallet.address())
      .mintAssets( {[offerAsset]: 1n, [lenderAsset]: 1n}, redeemer)
      .attachMintingPolicy(mp)
      .payToContract(loanAddr, {
        inline: datum
      }, {[offerAsset]: 1n, [lenderAsset]: 1n, lovelace: 13000000n })
      .complete()

    console.log("Create Offer Fee: " + tx.fee)
    const signedTx = await tx.sign().complete();
    return signedTx.submit();
  }

  async function closeOffer(): Promise<TxHash> {
    lucid.selectWalletFromSeed(lenderSeed);
    const closeOfferRedeemer = Data.to("CloseOffer", Loan.redeemer);
    const burnRedeemer = Data.to("BurnBeaconToken", Beacon.redeemer);
    const utxos = await lucid.utxosAt(loanAddr);
    const tx = await lucid
      .newTx()
      .collectFrom(utxos, closeOfferRedeemer)
      .addSigner(await lucid.wallet.address())
      .mintAssets( {[offerAsset]: -1n, [lenderAsset]: -1n}, burnRedeemer)
      .attachMintingPolicy(mp)
      .attachSpendingValidator(loan)
      .complete();

    console.log("Close Offer Fee: " + tx.fee)
    const signedTx = await tx.sign().complete();
    return signedTx.submit();
  }

  async function acceptOffer(): Promise<TxHash> {
    lucid.selectWalletFromSeed(borrowerSeed);
    const acceptOfferRedeemer = Data.to("AcceptOffer", Loan.redeemer);
    const mintActiveRedeemer = Data.to({
      MintActiveToken: [bStakeKeyHash, lPaymentKeyHash]
    }, Beacon.redeemer)
    const utxos = await lucid.utxosAt(loanAddr);
    const datum = Data.to({
      ActiveDatum: {
        loanBeacon: policyId,
        lenderId: lPaymentKeyHash,
        borrowerId: bStakeKeyHash,
        loanAsset: ["", ""],
        principle: 10000000n,
        term: BigInt(term),
        interest: { numerator: 1n, denominator: 20n},
        collateralization: new Map([[assetTuple, { numerator: 1n, denominator: 500000n}]]),
        expirationSlot: BigInt(startSlot + term),
        balanceOwed: { numerator: 10500000n, denominator: 1n}
      }
    }, Loan.datum);

    const tx = await lucid
      .newTx()
      .collectFrom(utxos, acceptOfferRedeemer)
      .addSigner(await lucid.wallet.address())
      .addSigner((await lucid.wallet.rewardAddress())!)
      .attachSpendingValidator(loan)
      .mintAssets( {[offerAsset]: -1n, [askAsset]: -1n, [activeAsset]: 1n, [borrowerAsset]: 1n}, mintActiveRedeemer)
      .attachMintingPolicy(mp)
      .payToContract(loanAddr, {
          inline: datum
      }, {[borrowerAsset]: 1n, [lenderAsset]: 1n, [activeAsset]: 1n, [collateralAsset]: 20n, lovelace: 3000000n })
      .payToAddress(await lucid.wallet.address(), {lovelace: 10000000n})
      .validFrom(startTime)
      .complete()

    console.log("Accept Offer Fee: " + tx.fee)
    const signedTx = await tx.sign().complete();
    return signedTx.submit();
  }

  async function partialRepayment(): Promise<TxHash> {
    lucid.selectWalletFromSeed(borrowerSeed);
    const now = emulator.time
    const repayRedeemer = Data.to("RepayLoan", Loan.redeemer);
    const utxos = await lucid.utxosAt(loanAddr);
    const datum = Data.to({
      ActiveDatum: {
        loanBeacon: policyId,
        lenderId: lPaymentKeyHash,
        borrowerId: bStakeKeyHash,
        loanAsset: ["", ""],
        principle: 10000000n,
        term: BigInt(term),
        interest: { numerator: 1n, denominator: 20n},
        collateralization: new Map([[assetTuple, { numerator: 1n, denominator: 500000n}]]),
        expirationSlot: BigInt(startSlot + term),
        balanceOwed: { numerator: 5250000n, denominator: 1n}
        }
    }, Loan.datum);

    const tx = await lucid
      .newTx()
      .collectFrom(utxos, repayRedeemer)
      .addSigner(await lucid.wallet.address())
      .addSigner((await lucid.wallet.rewardAddress())!)
      .attachSpendingValidator(loan)
      .payToContract(loanAddr, {
        inline: datum
      }, {[borrowerAsset]: 1n, [lenderAsset]: 1n, [activeAsset]: 1n, [collateralAsset]: 10n, lovelace: 8250000n })
      .payToAddress(await lucid.wallet.address(), {[collateralAsset]: 10n})
      .validTo(now + 500000)
      .complete()

    console.log("Partial Repayment Fee: " + tx.fee)
    const signedTx = await tx.sign().complete();
    return signedTx.submit();
  }

  async function fullRepayment(): Promise<TxHash> {
    lucid.selectWalletFromSeed(borrowerSeed);
    const now = emulator.time;
    const repayRedeemer = Data.to("RepayLoan", Loan.redeemer);
    const burnRedeemer = Data.to("BurnBeaconToken", Beacon.redeemer)
    const utxos = await lucid.utxosAt(loanAddr);
    const datum = Data.to({
      ActiveDatum: {
        loanBeacon: policyId,
        lenderId: lPaymentKeyHash,
        borrowerId: bStakeKeyHash,
        loanAsset: ["", ""],
        principle: 10000000n,
        term: BigInt(term),
        interest: { numerator: 1n, denominator: 20n},
        collateralization: new Map([[assetTuple, { numerator: 1n, denominator: 500000n}]]),
        expirationSlot: BigInt(startSlot + term),
        balanceOwed: { numerator: 0n, denominator: 1n}
        }
    }, Loan.datum);

    const tx = await lucid
      .newTx()
      .collectFrom(utxos, repayRedeemer)
      .addSigner(await lucid.wallet.address())
      .addSigner((await lucid.wallet.rewardAddress())!)
      .mintAssets( {[borrowerAsset]: -1n}, burnRedeemer)
      .attachMintingPolicy(mp)
      .attachSpendingValidator(loan)
      .payToContract(loanAddr, {
        inline: datum
      }, {[lenderAsset]: 1n, [activeAsset]: 1n, lovelace: 13500000n })
      .payToAddress(await lucid.wallet.address(), {[collateralAsset]: 10n})
      .validTo(now + 500000)
      .complete()

    console.log("Full Repayment Fee: " + tx.fee)
    const signedTx = await tx.sign().complete();
    return signedTx.submit();
  }

  async function claim(): Promise<TxHash> {
    lucid.selectWalletFromSeed(lenderSeed);
    const now = emulator.time
    const claimRedeemer = Data.to("Claim", Loan.redeemer);
    const burnRedeemer = Data.to("BurnBeaconToken", Beacon.redeemer)
    const utxos = await lucid.utxosAt(loanAddr);
    const tx = await lucid
      .newTx()
      .collectFrom(utxos, claimRedeemer)
      .addSigner(await lucid.wallet.address())
      .mintAssets( {[lenderAsset]: -1n, [activeAsset]: -1n}, burnRedeemer)
      .attachMintingPolicy(mp)
      .attachSpendingValidator(loan)
      .payToAddress(await lucid.wallet.address(), {lovelace: 13500000n})
      .validFrom(now)
      .complete()

    console.log("Claim Fee: " + tx.fee)
    const signedTx = await tx.sign().complete();
    return signedTx.submit();
  }