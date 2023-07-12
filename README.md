# A Cardano Loans Aiken Implementation
This project attempts to translate the proof of concept version of cardano-loans here https://github.com/fallen-icarus/cardano-loans from plutus-tx to Aiken.

## Motivation
A project for me to learn more about beacon tokens (I'm a big fan) and gain experience with Aiken. I also learned a lot about smart contracts on Cardano in general thanks to the wonderfully documented code in the original repo.

## Current Status
I've completed the translation of the smart contract code and added a basic set of end to end tests using the Lucid emulator which outputs the actions you can take along with their costs, run using a single asset as collateral.

cd test

deno run --allow-net test.ts

Create Ask Fee: .385011 ADA

Close Ask Fee: .696675 ADA

Create Offer Fee: 0.389865 ADA

Close Offer Fee: 0.706932 ADA

Accept Offer Fee: 0.928972 ADA

Partial Repayment Fee: 0.623173 ADA

Full Repayment Fee: 0.788642 ADA

Claim Fee: 0.719678 ADA



