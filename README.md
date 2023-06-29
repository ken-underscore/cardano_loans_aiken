# A Cardano Loans Aiken Implementation

## Motivation
I've been a fan of the beacon tokens pattern for a little while now and I was looking for a project to get my hands dirty with Aiken, so this was a two birds one stone kind of deal.

## Current Status
I completed translating the plutus tx implementation to Aiken but I have currently only tested a basic happy path. My testing was done manually via some hacked together Lucid code and web wallets, quite tedious/slow. Before testing/benchmarking the rest I will attempt to translate the Lucid code into end-to-end tests using the Lucid emulator instead.

Create an Ask - 0.386463 ADA

Close an Ask - Not tested

Create an Offer - 0.389753 ADA

Close an Offer - Not tested

Accept an Offer - 0.918352 ADA

Make a partial payment - 0.621829 ADA

Fully pay off loan - 0.783467 ADA

Claim an expired loan - Not tested

Claim a fully paid off loan - 0.7131 ADA

## Todo
Translate Lucid code into end-to-end tests with Lucid emulator

Try some performance tuning, first pass was just to get something working

Make repo public

Include benchmarks that make use of reference scripts

Add one of the "Potential Future Features"

