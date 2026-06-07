# 1TOPs-IIITB
This repository is created for the IIIT Bangalore team as part of the 1TOPs programme

# Important
1) RTL - > Core - Main source files
       - > Posit - MAC having Posit support
2) Scripts - > Cadence : Directory structure TBA
3) Testbenches - Basic versions. Tested in Vivado 2023.1.
4) Verification Suite - > TBA
5) Fixes -> Containing common issues with respective fixes.

## Current Status
1) Core developed with minimal support.
   * Testbench Version 1 all tests passed.
   * Testbench Version 2 - 19/48 tests passed. (Mimicked ISA Compliance tests from literature). NOT SELF WRITTEN.
2) Blocks - Interrupt Controllers, MMU, CSR
   * Sourced from PULP platform. NOT SELF WRITTEN.
   * Need to integrate and verify.
3) Cadence Scripts
   * Working for 45nm.
   * Xcelium with UVM packages support - TBA
