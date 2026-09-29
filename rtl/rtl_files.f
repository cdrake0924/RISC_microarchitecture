// RTL file list for the extended Ibex core complex (ibex_cc_top).
// Paths are relative to the repository root. Consumed by sim/Makefile (verilator -f).

// ---- include directories ----
+incdir+rtl/include
+incdir+ibex/rtl
+incdir+ibex/vendor/lowrisc_ip/ip/prim/rtl
+incdir+ibex/vendor/lowrisc_ip/dv/sv/dv_utils

// ---- packages (order matters) ----
ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_util_pkg.sv
ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_mubi_pkg.sv
ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_pkg.sv
ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_cipher_pkg.sv
ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_count_pkg.sv
ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_ram_1p_pkg.sv
rtl/ibex_uarch_pkg.sv
ibex/rtl/ibex_pkg.sv
ibex/rtl/ibex_tracer_pkg.sv

// ---- lowRISC primitives (generic technology) ----
ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_buf.sv
ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_flop.sv
ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_and2.sv
ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_clock_gating.sv
ibex/vendor/lowrisc_ip/ip/prim_generic/rtl/prim_clock_mux2.sv
ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_onehot_check.sv
ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_dec.sv
ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_secded_inv_39_32_enc.sv

// ---- upstream Ibex (with [uarch] modifications) ----
ibex/rtl/ibex_alu.sv
ibex/rtl/ibex_branch_predict.sv
ibex/rtl/ibex_compressed_decoder.sv
ibex/rtl/ibex_controller.sv
ibex/rtl/ibex_counter.sv
ibex/rtl/ibex_csr.sv
ibex/rtl/ibex_cs_registers.sv
ibex/rtl/ibex_decoder.sv
ibex/rtl/ibex_dummy_instr.sv
ibex/rtl/ibex_ex_block.sv
ibex/rtl/ibex_fetch_fifo.sv
ibex/rtl/ibex_id_stage.sv
ibex/rtl/ibex_if_stage.sv
ibex/rtl/ibex_load_store_unit.sv
ibex/rtl/ibex_multdiv_fast.sv
ibex/rtl/ibex_multdiv_slow.sv
ibex/rtl/ibex_pmp.sv
ibex/rtl/ibex_prefetch_buffer.sv
ibex/rtl/ibex_register_file_ff.sv
ibex/rtl/ibex_wb_stage.sv
ibex/rtl/ibex_core.sv
ibex/rtl/ibex_top.sv
ibex/rtl/ibex_tracer.sv

// ---- micro-architecture extensions ----
rtl/ibex_bp_dynamic.sv
rtl/cache/ibex_l1_repl.sv
rtl/cache/ibex_l1_cache.sv
rtl/cache/ibex_l1_prefetch.sv
rtl/ibex_cc_top.sv
