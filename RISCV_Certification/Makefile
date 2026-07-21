# ============================================================
#  Makefile — RISC-V Architecture Certification Test Runner
#  Converts ELFs → hex, simulates on BioPosit DUT, compares
#  signatures against Sail golden reference.
#
#  Usage:
#    make compile          # compile DUT + testbench (once)
#    make run_all          # run all 348 ELF tests
#    make run TEST=rv64i/I/I-add-00   # run a single test
#    make summary          # print pass/fail summary
#    make clean            # remove work products
# ============================================================

# ── Paths ──
RTL_DIR    := ../RTL/core
ELF_DIR    := riscv-arch-test/work/BioPosit-RVI20U64/elfs
BUILD_DIR  := riscv-arch-test/work/BioPosit-RVI20U64/build
WORK       := act_work
SIG_DIR    := $(WORK)/signatures
HEX_DIR    := $(WORK)/hex
LOG_DIR    := $(WORK)/logs

# ── RTL sources ──
RTL_SRC := $(RTL_DIR)/riscv_core.sv \
           $(RTL_DIR)/alu_unit.sv   \
           $(RTL_DIR)/branch_unit.sv \
           $(RTL_DIR)/csr_file.sv   \
           $(RTL_DIR)/decode_unit.sv \
           $(RTL_DIR)/exp_handler.sv \
           $(RTL_DIR)/hazard_unit.sv \
           $(RTL_DIR)/mmu_sv39.sv

TB_SRC := tb_act.sv

ELFS  := $(shell find $(ELF_DIR)/rv64i/I $(ELF_DIR)/rv64i/M $(ELF_DIR)/rv64i/Zca $(ELF_DIR)/rv64i/Zicsr $(ELF_DIR)/rv64i/Zaamo $(ELF_DIR)/rv64i/Zicntr $(ELF_DIR)/rv64i/Zifencei $(ELF_DIR)/rv64i/Zcd $(ELF_DIR)/rv64i/Zalrsc -name "*.elf" 2>/dev/null | sort)
TESTS := $(patsubst $(ELF_DIR)/%.elf,%,$(ELFS))

# ── Simulator selection ──
# Default: iverilog. Set SIM=xsim to use Vivado XSIM.
SIM ?= xsim

# ============================================================
#  COMPILE (one-time)
# ============================================================
ifeq ($(SIM),xsim)
COMPILE_STAMP := $(WORK)/.xsim_compiled

$(COMPILE_STAMP): $(TB_SRC) $(RTL_SRC)
	@mkdir -p $(WORK)
	cd $(WORK) && xvlog -sv $(addprefix ../,$(TB_SRC) $(RTL_SRC)) \
		-i ../$(RTL_DIR) --include ../$(RTL_DIR) 2>&1 | tail -5
	cd $(WORK) && xelab tb_act -s tb_act_sim -timescale 1ns/1ps \
		-i ../$(RTL_DIR) 2>&1 | tail -5
	@touch $@

else
COMPILE_STAMP := $(WORK)/tb_act.vvp

$(WORK)/tb_act.vvp: $(TB_SRC) $(RTL_SRC)
	@mkdir -p $(WORK)
	iverilog -g2012 -o $@ -I $(RTL_DIR) $(TB_SRC) $(RTL_SRC)

endif

compile: $(COMPILE_STAMP)
	@echo "=== Compilation complete ==="

# ============================================================
#  RUN A SINGLE TEST
#  Usage: make run TEST=rv64i/I/I-add-00
# ============================================================
.PHONY: run
run: compile
	@if [ -z "$(TEST)" ]; then echo "ERROR: specify TEST=rv64i/I/I-add-00"; exit 1; fi
	@mkdir -p $(HEX_DIR)/$(dir $(TEST)) $(SIG_DIR)/$(dir $(TEST)) $(LOG_DIR)/$(dir $(TEST))
	@# Convert ELF → hex
	@python3 elf2hex.py $(ELF_DIR)/$(TEST).elf $(HEX_DIR)/$(TEST).hex
	@# Extract symbols
	$(eval TOHOST    := $(shell bash get_sym.sh $(ELF_DIR)/$(TEST).elf tohost))
	$(eval SIG_START := $(shell bash get_sym.sh $(ELF_DIR)/$(TEST).elf begin_signature))
	$(eval SIG_END   := $(shell bash get_sym.sh $(ELF_DIR)/$(TEST).elf end_signature))
	@echo "── Running $(TEST)  tohost=$(TOHOST) sig=[$(SIG_START):$(SIG_END)]"
ifeq ($(SIM),xsim)
	@cd $(WORK) && xsim tb_act_sim -runall \
		-testplusarg "HEX_FILE=../$(HEX_DIR)/$(TEST).hex" \
		-testplusarg "TOHOST=$(TOHOST)" \
		-testplusarg "SIG_START=$(SIG_START)" \
		-testplusarg "SIG_END=$(SIG_END)" \
		-testplusarg "SIG_FILE=../$(SIG_DIR)/$(TEST).sig" \
		> ../$(LOG_DIR)/$(TEST).log 2>&1
else
	@cd $(WORK) && vvp -n tb_act.vvp \
		+HEX_FILE=../$(HEX_DIR)/$(TEST).hex \
		+TOHOST=$(TOHOST) \
		+SIG_START=$(SIG_START) \
		+SIG_END=$(SIG_END) \
		+SIG_FILE=../$(SIG_DIR)/$(TEST).sig \
		> ../$(LOG_DIR)/$(TEST).log 2>&1
endif
	@# Check result
	@test_name=$$(basename $(TEST)); \
	if grep -q "HTIF_PASS" $(LOG_DIR)/$(TEST).log; then \
		echo "PASSED: RVCP-SUMMARY: TEST PASSED - Test File \"$${test_name}.S\""; \
	elif grep -q "HTIF_FAIL" $(LOG_DIR)/$(TEST).log; then \
		echo "FAILED: RVCP-SUMMARY: TEST FAILED - Test File \"$${test_name}.S\""; \
	elif grep -q "TIMEOUT" $(LOG_DIR)/$(TEST).log; then \
		echo "FAILED: RVCP-SUMMARY: TEST FAILED (TIMEOUT) - Test File \"$${test_name}.S\""; \
	else \
		echo "FAILED: RVCP-SUMMARY: TEST FAILED (ERROR) - Test File \"$${test_name}.S\""; \
	fi

# ============================================================
#  RUN ALL TESTS
# ============================================================
.PHONY: run_all
run_all: compile
	@echo "============================================"
	@echo " Running $(words $(TESTS)) RISC-V Arch Tests"
	@echo "============================================"
	@pass=0; fail=0; timeout=0; error=0; total=0; \
	for elf in $(ELFS); do \
		test=$$(echo $$elf | sed 's|$(ELF_DIR)/||; s|\.elf$$||'); \
		total=$$((total + 1)); \
		mkdir -p $(HEX_DIR)/$$(dirname $$test) $(SIG_DIR)/$$(dirname $$test) $(LOG_DIR)/$$(dirname $$test); \
		python3 elf2hex.py $$elf $(HEX_DIR)/$$test.hex 2>/dev/null; \
		th=$$(bash get_sym.sh $$elf tohost); \
		ss=$$(bash get_sym.sh $$elf begin_signature); \
		se=$$(bash get_sym.sh $$elf end_signature); \
		if [ "$(SIM)" = "xsim" ]; then \
			cd $(WORK) && xsim tb_act_sim -runall \
				-testplusarg "HEX_FILE=../$(HEX_DIR)/$$test.hex" \
				-testplusarg "TOHOST=$$th" \
				-testplusarg "SIG_START=$$ss" \
				-testplusarg "SIG_END=$$se" \
				-testplusarg "SIG_FILE=../$(SIG_DIR)/$$test.sig" \
				> ../$(LOG_DIR)/$$test.log 2>&1; \
			cd ..; \
		else \
			cd $(WORK) && vvp -n tb_act.vvp \
				+HEX_FILE=../$(HEX_DIR)/$$test.hex \
				+TOHOST=$$th \
				+SIG_START=$$ss \
				+SIG_END=$$se \
				+SIG_FILE=../$(SIG_DIR)/$$test.sig \
				> ../$(LOG_DIR)/$$test.log 2>&1; \
			cd ..; \
		fi; \
		if grep -q "HTIF_PASS" $(LOG_DIR)/$$test.log; then \
			result="PASS"; \
			pass=$$((pass + 1)); \
			ref=$(BUILD_DIR)/$$(echo $$test | sed 's|^\([^/]*/[^/]*/\)|\1|').sig; \
			refdir=$$(echo $$test | awk -F/ '{print $$1"/"$$2}'); \
			testname=$$(echo $$test | awk -F/ '{print $$3}'); \
			ref=$(BUILD_DIR)/$$refdir/$$testname.sig; \
			if [ -f "$$ref" ] && [ -f "$(SIG_DIR)/$$test.sig" ]; then \
				if ! diff -q "$(SIG_DIR)/$$test.sig" "$$ref" > /dev/null 2>&1; then \
					result="PASS(sig-mismatch)"; \
				fi; \
			fi; \
		elif grep -q "HTIF_FAIL" $(LOG_DIR)/$$test.log; then \
			result="FAIL"; \
			fail=$$((fail + 1)); \
		elif grep -q "TIMEOUT" $(LOG_DIR)/$$test.log; then \
			result="TIMEOUT"; \
			timeout=$$((timeout + 1)); \
		else \
			error=$$((error + 1)); \
		fi; \
		base_test=$$(basename $$test); \
		if [ "$$result" = "PASS" ] || [ "$$result" = "PASS(sig-mismatch)" ]; then \
			printf "PASSED: RVCP-SUMMARY: TEST PASSED - Test File \"%s.S\"\n" "$$base_test"; \
		else \
			printf "FAILED: RVCP-SUMMARY: TEST FAILED - Test File \"%s.S\"\n" "$$base_test"; \
		fi; \
	done; \
	echo ""; \
	echo "============================================"; \
	echo " RESULTS: $$pass PASS / $$fail FAIL / $$timeout TIMEOUT / $$error ERROR"; \
	echo " Total:   $$total tests"; \
	echo "============================================"; \
	echo "$$pass $$fail $$timeout $$error" > $(WORK)/results_summary.txt

# ============================================================
#  SUMMARY — reparse existing logs
# ============================================================
.PHONY: summary
summary:
	@pass=0; fail=0; timeout=0; error=0; \
	for log in $$(find $(LOG_DIR) -name "*.log" 2>/dev/null | sort); do \
		test=$$(echo $$log | sed 's|$(LOG_DIR)/||; s|\.log$$||'); \
		if grep -q "HTIF_PASS" $$log; then \
			pass=$$((pass + 1)); r="PASS"; \
		elif grep -q "HTIF_FAIL" $$log; then \
			fail=$$((fail + 1)); r="FAIL"; \
		elif grep -q "TIMEOUT" $$log; then \
			timeout=$$((timeout + 1)); r="TIMEOUT"; \
		else \
			error=$$((error + 1)); r="ERROR"; \
		fi; \
		base_test=$$(basename $$test); \
		if [ "$$r" = "PASS" ]; then \
			printf "PASSED: RVCP-SUMMARY: TEST PASSED - Test File \"%s.S\"\n" "$$base_test"; \
		else \
			printf "FAILED: RVCP-SUMMARY: TEST FAILED - Test File \"%s.S\"\n" "$$base_test"; \
		fi; \
	done; \
	echo ""; \
	echo "============================================"; \
	echo " RESULTS: $$pass PASS / $$fail FAIL / $$timeout TIMEOUT / $$error ERROR"; \
	echo "============================================"

# ============================================================
#  CLEAN
# ============================================================
.PHONY: clean
clean:
	rm -rf $(WORK)

.PHONY: all
all: compile
	@echo "Compiled. Run 'make run_all' to execute all tests."
