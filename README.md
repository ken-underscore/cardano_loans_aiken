# A Cardano Loans Aiken Implementation
This project attempts to translate the proof of concept version of cardano-loans here https://github.com/fallen-icarus/cardano-loans from plutus-tx to Aiken.

## Motivation
A project for me to learn more about beacon tokens (I'm a big fan) and gain experience with Aiken. I also learned a lot about smart contracts on Cardano in general thanks to the wonderfully documented code in the original repo.

## Current Status
I've completed the translation of the smart contract code and added a basic set of end to end tests using the Lucid emulator which outputs the actions you can take along with their costs, run using a single asset as collateral.

Create Ask Fee: 385011

Close Ask Fee: 696675

Create Offer Fee: 389865

Close Offer Fee: 706932

Accept Offer Fee: 928972

Partial Repayment Fee: 623173

Full Repayment Fee: 788642

Claim Fee: 719678



