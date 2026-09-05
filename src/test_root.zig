//! Unit-test root kept separate from the production executable root.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const test_shards = @import("test_shards.zig");

// main.zig owns the aggregate import list for now; rooting tests here keeps the
// build graph free to compile the production artifact and test suite as
// independent jobs without giving either artifact the other's root identity.
test {
    // EXHAUSTIVE import bridge: every module whose tests the suite runs.
    //
    // Zig collects a file's tests only when the file is ANALYZED, and
    // `--test-filter` cannot reach that decision — it drops tests in the
    // compiler. So a module the whole suite only analyzes because some OTHER
    // module's test body touches it stops being analyzed the moment that body
    // is filtered into a different shard, and its own tests are then compiled
    // into no binary at all. Measured on the first sharded build: 49 tests
    // gone, all eight shards green.
    //
    // An unnamed `test { }` block is linked into every filtered binary whatever
    // the filters say, so listing every module here makes each shard's contents
    // a function of its filters ALONE. That is what lets the shard layout be
    // rebalanced — a different shard count, a file moved between shards —
    // without the partition quietly losing tests it no longer analyzes.
    //
    // The list is exhaustive by test ("the shard import bridge lists every
    // module whose tests run"), not by discipline — and since 2026-08-17 it is
    // exhaustive over the whole tree. The nine `src/serve/*.zig` modules the
    // manifest used to carve out as `unanalyzed_modules` (reachable from
    // `serve.zig` only inside route-registration bodies the test binary never
    // analyzes) are bridged here like every other module, so the 23 tests they
    // declare run. No test-bearing module in src/ is skipped any more, which is
    // why nothing below consults an exemption list.
    _ = @import("bench_route.zig");
    _ = @import("bench_page.zig");
    _ = @import("authored_heatsink.zig");
    _ = @import("board_layers.zig");
    _ = @import("board_theme.zig");
    _ = @import("bom.zig");
    _ = @import("bom_resolve.zig");
    _ = @import("build_id.zig");
    _ = @import("canonical_module_check.zig");
    _ = @import("commands.zig");
    _ = @import("component_classification.zig");
    _ = @import("config.zig");
    _ = @import("convert/alt_functions.zig");
    _ = @import("convert/footprint.zig");
    _ = @import("convert/symbol.zig");
    _ = @import("coverage.zig");
    _ = @import("decouple_key.zig");
    _ = @import("deflate.zig");
    _ = @import("diagram/classify.zig");
    _ = @import("diagram/collect.zig");
    _ = @import("diagram/diagram.zig");
    _ = @import("diagram/layout.zig");
    _ = @import("diagram/lod.zig");
    _ = @import("diagram/membership.zig");
    _ = @import("diagram/render.zig");
    _ = @import("diagram/system_of_boards.zig");
    _ = @import("deploy_unit.zig");
    _ = @import("docgen.zig");
    _ = @import("drc_dump.zig");
    _ = @import("power_flow_cli.zig");
    _ = @import("export_names.zig");
    _ = @import("export_pinmap.zig");
    _ = @import("export_spice.zig");
    _ = @import("gerber_dump.zig");
    _ = @import("netlist_dump.zig");
    _ = @import("pins_by_name.zig");
    _ = @import("drc_reconcile.zig");
    _ = @import("drc_sweep.zig");
    _ = @import("drc_session.zig");
    _ = @import("drc_board_json.zig");
    _ = @import("emit.zig");
    _ = @import("erc.zig");
    _ = @import("erc_interface.zig");
    _ = @import("escape.zig");
    _ = @import("eval/authored_rules.zig");
    _ = @import("eval/board_keepout.zig");
    _ = @import("eval/board_role_cases.zig");
    _ = @import("eval/builders.zig");
    _ = @import("eval/builtins.zig");
    _ = @import("eval/check_grammar.zig");
    _ = @import("eval/attrs.zig");
    _ = @import("eval/design_block.zig");
    _ = @import("eval/electrical.zig");
    _ = @import("eval/env.zig");
    _ = @import("eval/evaluator.zig");
    _ = @import("eval/fmt.zig");
    _ = @import("eval/deprecations.zig");
    _ = @import("eval/forms.zig");
    _ = @import("eval/ids.zig");
    _ = @import("eval/instance.zig");
    _ = @import("eval/interfaces.zig");
    _ = @import("eval/connect.zig");
    _ = @import("eval/micro_forms.zig");
    _ = @import("eval/modules.zig");
    _ = @import("eval/net_analysis.zig");
    _ = @import("eval/net_suggest.zig");
    _ = @import("eval/pin_enrichment.zig");
    _ = @import("eval/power_budget.zig");
    _ = @import("eval/power_sequencing.zig");
    _ = @import("eval/project_boards.zig");
    _ = @import("eval/net_envelopes.zig");
    _ = @import("eval/net_envelope_rules.zig");
    _ = @import("eval/rails.zig");
    _ = @import("eval/scope_control.zig");
    _ = @import("eval/sidecars.zig");
    _ = @import("eval/section_maturity.zig");
    _ = @import("eval/stackup_presets.zig");
    _ = @import("eval/suggest.zig");
    _ = @import("query.zig");
    _ = @import("eval/value_kind.zig");
    _ = @import("eval/variants.zig");
    _ = @import("eval/footprint_pads.zig");
    _ = @import("eval/test_point.zig");
    _ = @import("eval/thermal.zig");
    _ = @import("eval/validate.zig");
    _ = @import("exit.zig");
    _ = @import("export_fab.zig");
    _ = @import("export_gerber.zig");
    _ = @import("panelize.zig");
    _ = @import("export_kicad.zig");
    _ = @import("export_kicad_footprint.zig");
    _ = @import("export_kicad_netlist.zig");
    _ = @import("export_kicad_sch.zig");
    _ = @import("export_elmer_thermal.zig");
    _ = @import("elmer_thermal_command.zig");
    _ = @import("export_matlab_rf.zig");
    _ = @import("export_pdf.zig");
    _ = @import("fab_identity.zig");
    _ = @import("fab_package.zig");
    _ = @import("fab_gate.zig");
    _ = @import("fab_preview.zig");
    _ = @import("fab_readiness.zig");
    _ = @import("fab_release.zig");
    _ = @import("fab_schematic_gate.zig");
    _ = @import("route_repair.zig");
    _ = @import("route_resume.zig");
    _ = @import("flat_netlist.zig");
    _ = @import("font5x7.zig");
    _ = @import("frequency_plan.zig");
    _ = @import("gerber_verify.zig");
    _ = @import("githash.zig");
    _ = @import("id_insert.zig");
    _ = @import("import_fold.zig");
    _ = @import("import_fold_emit.zig");
    _ = @import("import_kicad.zig");
    _ = @import("infra/atomic_write.zig");
    _ = @import("infra/source_transaction.zig");
    _ = @import("infra/fs.zig");
    _ = @import("infra/process_alloc.zig");
    _ = @import("infra/random.zig");
    _ = @import("json_writer.zig");
    _ = @import("kicad_pcb/experiment.zig");
    _ = @import("kicad_pcb/format.zig");
    _ = @import("kicad_pcb/import_layout.zig");
    _ = @import("kicad_pcb/import_layout_command.zig");
    _ = @import("kicad_pcb/import_layout_json.zig");
    _ = @import("kicad_pcb/inspect.zig");
    _ = @import("kicad_pcb/net_aliases.zig");
    _ = @import("kicad_pcb/project_rules.zig");
    _ = @import("kicad_pcb/reader.zig");
    _ = @import("kicad_pcb/reference_guides.zig");
    _ = @import("kicad_pcb/route_command.zig");
    _ = @import("kicad_pcb/route_score.zig");
    _ = @import("kicad_pcb/router_adapter.zig");
    _ = @import("kicad_pcb/snapshot.zig");
    _ = @import("kicad_pcb/writer.zig");
    _ = @import("kicad_sch/bank.zig");
    _ = @import("kicad_sch/compose.zig");
    _ = @import("kicad_sch/emit.zig");
    _ = @import("kicad_sch/gang.zig");
    _ = @import("kicad_sch/glyph.zig");
    _ = @import("kicad_sch/plan.zig");
    _ = @import("kicad_sch/project.zig");
    _ = @import("kicad_sch/shape.zig");
    _ = @import("kicad_sch/sheet.zig");
    _ = @import("kicad_sch/stagger.zig");
    _ = @import("kicad_sch/stub.zig");
    _ = @import("kicad_sch/textbox.zig");
    _ = @import("kicad_sch/vendor.zig");
    _ = @import("kicad_sch/verify.zig");
    _ = @import("kicad_sch/wire.zig");
    _ = @import("kicad_sch_push.zig");
    _ = @import("kicad_sym/library.zig");
    _ = @import("kicad_sym/reader.zig");
    _ = @import("layout_status.zig");
    _ = @import("leak_tests/checks.zig");
    _ = @import("leak_tests/diagram.zig");
    _ = @import("leak_tests/eval_core.zig");
    _ = @import("leak_tests/import_export.zig");
    _ = @import("leak_tests/placement.zig");
    _ = @import("leak_tests/render.zig");
    _ = @import("leak_tests/review_bom.zig");
    _ = @import("leak_tests/serve_auth_request.zig");
    _ = @import("leak_tests/serve_ward_request.zig");
    _ = @import("leak_tests/serve_request.zig");
    _ = @import("leak_tests/serve_stores.zig");
    _ = @import("leak_tests/sexpr.zig");
    _ = @import("lib_limits.zig");
    _ = @import("main.zig");
    _ = @import("module_metadata.zig");
    _ = @import("net_name.zig");
    _ = @import("numeric.zig");
    _ = @import("poly_scanline.zig");
    _ = @import("parts.zig");
    _ = @import("paths.zig");
    _ = @import("stdlib.zig");
    _ = @import("pdf.zig");
    _ = @import("pdf_afm.zig");
    _ = @import("pdf_verify.zig");
    _ = @import("pll_loop.zig");
    _ = @import("split_design.zig");
    _ = @import("spurious.zig");
    _ = @import("power_integrity_json.zig");
    _ = @import("placement/airwire_geometry.zig");
    _ = @import("placement/bend_smooth.zig");
    _ = @import("placement/blocker_nomination.zig");
    _ = @import("placement/bypass_intent.zig");
    _ = @import("placement/bypass_open.zig");
    _ = @import("placement/cap_bind.zig");
    _ = @import("placement/cdt_layers.zig");
    _ = @import("placement/cdt_route.zig");
    _ = @import("placement/congestion.zig");
    _ = @import("placement/connector_pinout.zig");
    _ = @import("placement/content_key.zig");
    _ = @import("placement/copper_contact.zig");
    _ = @import("placement/copper_support.zig");
    _ = @import("placement/copper_length.zig");
    _ = @import("placement/copper_topology.zig");
    _ = @import("placement/copper_topology_route_regression.zig");
    _ = @import("placement/courtyard_close.zig");
    _ = @import("placement/critical_paths.zig");
    _ = @import("placement/critical_rough.zig");
    _ = @import("placement/critical_route_score.zig");
    _ = @import("placement/diff_couple.zig");
    _ = @import("placement/diff_direct.zig");
    _ = @import("placement/diff_pairs.zig");
    _ = @import("placement/diff_route.zig");
    _ = @import("placement/dive_elide.zig");
    _ = @import("placement/diff_shape.zig");
    _ = @import("placement/drc.zig");
    _ = @import("placement/drc_compose.zig");
    _ = @import("placement/drc_diffpair.zig");
    _ = @import("placement/drc_keepout.zig");
    _ = @import("placement/drc_match.zig");
    _ = @import("placement/board_keepout.zig");
    _ = @import("placement/drc_board_keepout.zig");
    _ = @import("placement/drc_perimeter_keepout.zig");
    _ = @import("placement/drc_power_width.zig");
    _ = @import("placement/drc_power_via.zig");
    _ = @import("placement/drc_pour.zig");
    _ = @import("placement/drc_scope.zig");
    _ = @import("placement/edge_rotation.zig");
    _ = @import("placement/escalate_retry.zig");
    _ = @import("placement/escape_assign.zig");
    _ = @import("placement/fill_cache.zig");
    _ = @import("placement/fine_accept.zig");
    _ = @import("placement/fine_window.zig");
    _ = @import("placement/gap_close_route.zig");
    _ = @import("placement/gap_policy.zig");
    _ = @import("placement/geometry.zig");
    _ = @import("placement/rf_pad_adapt.zig");
    _ = @import("ground_via_seed.zig");
    _ = @import("placement/guide_branch.zig");
    _ = @import("placement/elliptic_integral.zig");
    _ = @import("placement/impedance.zig");
    _ = @import("placement/impedance_field.zig");
    _ = @import("placement/impedance_microstrip.zig");
    _ = @import("placement/impedance_coupled_microstrip.zig");
    _ = @import("placement/impedance_coupled_stripline.zig");
    _ = @import("placement/impedance_cache.zig");
    _ = @import("placement/impedance_rules.zig");
    _ = @import("placement/implicit_plane.zig");
    _ = @import("placement/island_accept.zig");
    _ = @import("placement/joint_rescue.zig");
    _ = @import("placement/keepout.zig");
    _ = @import("placement/keepout_route.zig");
    _ = @import("placement/land_transit.zig");
    _ = @import("placement/lane_reserve.zig");
    _ = @import("placement/layout_lint.zig");
    _ = @import("placement/manhattan_route.zig");
    _ = @import("placement/mask_relief.zig");
    _ = @import("placement/match_group.zig");
    _ = @import("placement/maze_scratch.zig");
    _ = @import("placement/module_policy.zig");
    _ = @import("placement/near_bind.zig");
    _ = @import("placement/net_identity.zig");
    _ = @import("placement/net_rewrite_pass.zig");
    _ = @import("placement/net_graph.zig");
    _ = @import("placement/net_open.zig");
    _ = @import("placement/net_rules.zig");
    _ = @import("placement/net_topology.zig");
    _ = @import("placement/net_topology_route_regression.zig");
    _ = @import("placement/octilinear.zig");
    _ = @import("placement/optimizer.zig");
    _ = @import("placement/outline.zig");
    _ = @import("shape_sketch.zig");
    _ = @import("placement/pad_entry.zig");
    _ = @import("placement/pad_escape.zig");
    _ = @import("placement/pad_exit.zig");
    _ = @import("placement/pad_grid.zig");
    _ = @import("placement/pad_neck.zig");
    _ = @import("placement/path_copper.zig");
    _ = @import("placement/variable_width_copper.zig");
    _ = @import("pad_neck_shape.zig");
    _ = @import("placement/disc_stamp.zig");
    _ = @import("placement/pad_project.zig");
    _ = @import("placement/pad_shape.zig");
    _ = @import("placement/pad_world.zig");
    _ = @import("placement/perimeter_fence.zig");
    _ = @import("placement/pin_roles.zig");
    _ = @import("placement/plan_resolve.zig");
    _ = @import("placement/plane_stitch.zig");
    _ = @import("placement/plane_stitch_route_regression.zig");
    _ = @import("placement/detour_route_regression.zig");
    _ = @import("placement/ldo_route_quality_regression.zig");
    _ = @import("placement/plane_via.zig");
    _ = @import("placement/power_integrity.zig");
    _ = @import("placement/pdn_impedance.zig");
    _ = @import("placement/power_branch_width.zig");
    _ = @import("placement/power_capacity.zig");
    _ = @import("placement/power_current.zig");
    _ = @import("placement/port_escape.zig");
    _ = @import("placement/pose_math.zig");
    _ = @import("placement/pose_snapshot.zig");
    _ = @import("placement/pour.zig");
    _ = @import("placement/pour_patch_regression.zig");
    _ = @import("placement/progress.zig");
    _ = @import("placement/rf_path_solver.zig");
    _ = @import("placement/rf_port_finish.zig");
    _ = @import("placement/rf_port_frames.zig");
    _ = @import("placement/rf_shadow.zig");
    _ = @import("placement/rf_taper_paths.zig");
    _ = @import("placement/drc_return_path.zig");
    _ = @import("placement/rough_identity.zig");
    _ = @import("placement/rough_routability.zig");
    _ = @import("placement/routability_lint.zig");
    _ = @import("placement/route_cleanup.zig");
    _ = @import("placement/pair_pinch.zig");
    _ = @import("placement/pinch_probe.zig");
    _ = @import("placement/place_repair.zig");
    _ = @import("placement/route_close.zig");
    _ = @import("placement/route_determinism.zig");
    _ = @import("placement/route_diagnose.zig");
    _ = @import("placement/route_free_space.zig");
    _ = @import("placement/route_grid.zig");
    _ = @import("placement/route_policy.zig");
    _ = @import("placement/route_score.zig");
    _ = @import("placement/route_session.zig");
    _ = @import("placement/route_shape_score.zig");
    _ = @import("placement/route_space_cache.zig");
    _ = @import("placement/route_timing.zig");
    _ = @import("placement/routed_copper.zig");
    _ = @import("placement/router.zig");
    _ = @import("placement/router_ctx.zig");
    _ = @import("placement/router_gap_close.zig");
    _ = @import("placement/router_maze.zig");
    _ = @import("placement/router_via_rules.zig");
    _ = @import("placement/router_vision_regression.zig");
    _ = @import("placement/router_waypoint_regression.zig");
    _ = @import("placement/shove.zig");
    _ = @import("placement/straighten.zig");
    _ = @import("placement/thermal_field.zig");
    _ = @import("placement/topo_lower.zig");
    _ = @import("placement/topo_plan.zig");
    _ = @import("placement/trace_em.zig");
    _ = @import("placement/vacate_policy.zig");
    _ = @import("placement/via_antipad.zig");
    _ = @import("placement/via_centre.zig");
    _ = @import("placement/via_fence.zig");
    _ = @import("placement/via_guide.zig");
    _ = @import("placement/via_hop_scan.zig");
    _ = @import("placement/via_merge.zig");
    _ = @import("png.zig");
    _ = @import("preflight.zig");
    _ = @import("board_review_catalog.zig");
    _ = @import("board_review_state.zig");
    _ = @import("review_assessment.zig");
    _ = @import("review_datasheet_inventory.zig");
    _ = @import("review_audit.zig");
    _ = @import("review_profiles.zig");
    _ = @import("waiver_register.zig");
    _ = @import("raster.zig");
    _ = @import("refdes_stability.zig");
    _ = @import("render_html.zig");
    _ = @import("render_json.zig");
    _ = @import("render_order.zig");
    _ = @import("render_pcb_png.zig");
    _ = @import("render_schematic_png.zig");
    _ = @import("design_archive.zig");
    _ = @import("render_svg/branch.zig");
    _ = @import("render_svg/connection.zig");
    _ = @import("render_svg/context.zig");
    _ = @import("render_svg/draw.zig");
    _ = @import("render_svg/hub.zig");
    _ = @import("render_svg/schematic_walk.zig");
    _ = @import("render_svg/section_inset.zig");
    _ = @import("req_checks_cases.zig");
    _ = @import("req_derived_checks.zig");
    _ = @import("req_design_rules.zig");
    _ = @import("req_physical_checks.zig");
    _ = @import("req_physical_checks_cases.zig");
    _ = @import("review.zig");
    _ = @import("review_md.zig");
    _ = @import("system_review.zig");
    _ = @import("system_sexp.zig");
    _ = @import("system_interface_check.zig");
    _ = @import("system_review_assets.zig");
    _ = @import("system_review_html.zig");
    _ = @import("system_review_md.zig");
    _ = @import("system_review_pdf.zig");
    _ = @import("system_review_package.zig");
    _ = @import("mechanical/prismatic.zig");
    _ = @import("mechanical/enclosure.zig");
    _ = @import("mechanical/cad_document.zig");
    _ = @import("board_review_snapshot.zig");
    _ = @import("serve/fab_release_service.zig");
    _ = @import("serve/system_review_api.zig");
    _ = @import("serve/system_cad.zig");
    _ = @import("review_html.zig");
    _ = @import("review_thermal.zig");
    _ = @import("thermal_scenarios.zig");
    _ = @import("tool_cli.zig");
    _ = @import("render_thermal_png.zig");
    _ = @import("serve.zig");
    _ = @import("serve/assembly_debug.zig");
    _ = @import("serve/assembly_page_cache.zig");
    _ = @import("serve/api.zig");
    _ = @import("serve/pcb_step_export.zig");
    _ = @import("serve/auth.zig");
    _ = @import("serve/ward_auth.zig");
    _ = @import("serve/auth_store.zig");
    _ = @import("serve/autocommit.zig");
    _ = @import("serve/board_backup.zig");
    _ = @import("serve/board_review.zig");
    _ = @import("serve/mcp_board_review.zig");
    _ = @import("serve/bom_html.zig");
    _ = @import("serve/component_info.zig");
    _ = @import("serve/component_search.zig");
    _ = @import("serve/datasheet.zig");
    _ = @import("serve/datasheet_attach.zig");
    _ = @import("serve/datasheet_ref.zig");
    _ = @import("serve/design_archive_api.zig");
    _ = @import("serve/dossier_jobs.zig");
    _ = @import("serve/design_diff.zig");
    _ = @import("serve/design_rules_edit.zig");
    _ = @import("serve/diag_format.zig");
    _ = @import("serve/digikey.zig");
    _ = @import("serve/drc_json.zig");
    _ = @import("serve/drc_rules.zig");
    _ = @import("serve/edit.zig");
    _ = @import("serve/edit_request.zig");
    _ = @import("serve/edit_target.zig");
    _ = @import("serve/edit_contract_tests.zig");
    _ = @import("serve/edit_assist.zig");
    _ = @import("serve/fab_filename.zig");
    _ = @import("serve/footprint_editor.zig");
    _ = @import("serve/footprint_preview.zig");
    _ = @import("serve/gzip_cache.zig");
    _ = @import("serve/ground_vias.zig");
    _ = @import("serve/history.zig");
    _ = @import("serve/kicad_sch_export.zig");
    _ = @import("serve/layer_table_json.zig");
    _ = @import("serve/layout_backfill.zig");
    _ = @import("serve/layout_backfill_command.zig");
    _ = @import("serve/layout_layers.zig");
    _ = @import("serve/layout_match.zig");
    _ = @import("serve/layout_merge_command.zig");
    _ = @import("serve/layout_sidecar_json.zig");
    _ = @import("layout_save_layers.zig");
    _ = @import("layout_sidecar_store.zig");
    _ = @import("serve/library.zig");
    _ = @import("serve/library_3d.zig");
    _ = @import("serve/mcp_arg_names.zig");
    _ = @import("serve/mcp_checks.zig");
    _ = @import("serve/mcp_close_gaps.zig");
    _ = @import("route_cleanup_gate.zig");
    _ = @import("serve/mcp_connector_pinout.zig");
    _ = @import("serve/mcp_escape_assign.zig");
    _ = @import("serve/mcp_flatten.zig");
    _ = @import("serve/mcp_import_tools.zig");
    _ = @import("serve/mcp_kicad_sch.zig");
    _ = @import("serve/mcp_parts_tools.zig");
    _ = @import("serve/mcp_placement_sensitivity.zig");
    _ = @import("serve/mcp_read_opts.zig");
    _ = @import("serve/mcp_routability.zig");
    _ = @import("serve/mcp_route_experiment.zig");
    _ = @import("serve/mcp_route_order.zig");
    _ = @import("serve/mcp_route_trials.zig");
    _ = @import("serve/mcp_schematic_view.zig");
    _ = @import("serve/mcp_tools.zig");
    _ = @import("serve/mcp_fab_readiness.zig");
    _ = @import("serve/modules.zig");
    _ = @import("serve/navbar.zig");
    _ = @import("serve/notes.zig");
    _ = @import("serve/page_cache.zig");
    _ = @import("serve/pages.zig");
    _ = @import("serve/panel_export.zig");
    _ = @import("serve/pcb_describe.zig");
    _ = @import("serve/pcb_fence.zig");
    _ = @import("serve/pcb_keepout_json.zig");
    _ = @import("serve/pcb_layout_import.zig");
    _ = @import("serve/pcb_derived.zig");
    _ = @import("serve/pcb_layout_page.zig");
    _ = @import("serve/pose_identity.zig");
    _ = @import("serve/pcb_subseeds.zig");
    _ = @import("serve/pcb_layout_sync.zig");
    _ = @import("serve/pcb_page_cache.zig");
    _ = @import("serve/progress_cache.zig");
    _ = @import("serve/cache_core.zig");
    _ = @import("serve/page_cache_endpoint.zig");
    _ = @import("serve/describe_cache.zig");
    _ = @import("serve/read_cache.zig");
    _ = @import("serve/png_cache.zig");
    _ = @import("serve/pcb_part_json.zig");
    _ = @import("serve/pcb_progress.zig");
    _ = @import("serve/pcb_rules_json.zig");
    _ = @import("serve/placement_outline.zig");
    _ = @import("serve/shape_sketch_json.zig");
    _ = @import("serve/pour_json.zig");
    _ = @import("serve/rate_limiter.zig");
    _ = @import("serve/request_log.zig");
    _ = @import("serve/rework_guide.zig");
    _ = @import("serve/rough_best.zig");
    _ = @import("serve/route_analyze_api.zig");
    _ = @import("serve/route_live.zig");
    _ = @import("serve/route_plan.zig");
    _ = @import("serve/route_result_stats.zig");
    _ = @import("serve/route_review.zig");
    _ = @import("serve/route_session_api.zig");
    _ = @import("serve/route_vision.zig");
    _ = @import("serve/saved_anchor_migration.zig");
    _ = @import("serve/schematic_page.zig");
    _ = @import("serve/schematic_pdf.zig");
    _ = @import("serve/thermal_api.zig");
    _ = @import("serve/thermal_cache.zig");
    _ = @import("serve/thermal_page.zig");
    _ = @import("serve/urlcodec.zig");
    _ = @import("serve/schematic_viewer_js.zig");
    _ = @import("serve/static_assets.zig");
    _ = @import("serve/stuck_json.zig");
    _ = @import("serve/style_score.zig");
    _ = @import("serve/subcircuit_route.zig");
    _ = @import("serve/subprocess.zig");
    _ = @import("serve/sync.zig");
    _ = @import("serve/sync_kicad_sch.zig");
    _ = @import("serve/templates/html.zig");
    _ = @import("serve/twin_parity.zig");
    _ = @import("serve/upload.zig");
    _ = @import("serve/upload_datasheet.zig");
    _ = @import("serve/upload_package.zig");
    _ = @import("serve/vfs.zig");
    _ = @import("serve/warmup.zig");
    _ = @import("serve/warm_sched.zig");
    _ = @import("sexpr/ast.zig");
    _ = @import("sexpr/paren_span.zig");
    _ = @import("sexpr/parser.zig");
    _ = @import("sexpr/printer.zig");
    _ = @import("sexpr/tokenizer.zig");
    _ = @import("silk_font.zig");
    _ = @import("subcircuit_silkscreen.zig");
    _ = @import("subcircuit_seed_drc.zig");
    _ = @import("subcircuit_route_regression.zig");
    _ = @import("svg2pdf.zig");
    _ = @import("target_unblock.zig");
    _ = @import("testpoint_silkscreen.zig");
    _ = @import("wasm_drc.zig");
    _ = @import("uuid.zig");
    _ = @import("zipfile.zig");
}

fn readRepoFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return infra_fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
}

// ── Shard coverage ────────────────────────────────────────────────────────
//
// `zig build test` compiles one binary per entry in src/test_shards.zig and
// runs them concurrently, each binary selected by the compiler's
// `--test-filter`. That makes the suite as strong as the manifest and no
// stronger: a test no filter matches is never compiled into ANY shard, and it
// disappears exactly the way a deleted test does — silently, with every shard
// still green. A test two shards match runs twice, which is only wasteful, but
// it is the same manifest bug and worth the same failure.
//
// So the manifest is not trusted, it is checked, against the tree rather than
// against itself: read every `test "..."` in src/, spell each one the way the
// compiler names it, and require exactly one shard to claim it.

/// One fully-qualified test name, spelled the way Zig names it for
/// `--test-filter`: the source path relative to src/ with separators as dots,
/// then `.test.`, then the declared name.
const QualifiedName = []const u8;

/// Reads every named test in src/ into `arena`.
///
/// Deliberately a raw source scan and not a Zig parse: the compiler's own list
/// is exactly what a shard filter already produced, so deriving the expectation
/// from it would check the manifest against itself. Unnamed `test { }` blocks
/// are skipped — the compiler links them into every filtered binary whatever
/// the filters say, so no shard has to claim them.
fn collectQualifiedNames(
    arena: std.mem.Allocator,
    out: *std.ArrayList(QualifiedName),
) !void {
    var src = try infra_fs.cwd().openDir("src", .{ .iterate = true });
    defer src.close();
    var walker = try src.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const source = try src.readFileAlloc(arena, entry.path, 4 * 1024 * 1024);
        const prefix = try qualifiedPrefix(arena, entry.path);
        try appendNamedTests(arena, out, prefix, source);
    }
}

/// `placement/router.zig` → `placement.router.test.`
fn qualifiedPrefix(arena: std.mem.Allocator, rel_path: []const u8) ![]const u8 {
    const stem = rel_path[0 .. rel_path.len - ".zig".len];
    const dotted = try arena.dupe(u8, stem);
    std.mem.replaceScalar(u8, dotted, std.fs.path.sep, '.');
    return std.mem.concat(arena, u8, &.{ dotted, ".test." });
}

/// Appends `prefix ++ <declared name>` for every `test "..." {` in `source`.
/// Only a declaration at the start of a line counts, which is what makes the
/// scan agree with the compiler on this tree: the same rule reproduces the
/// suite's test count exactly.
fn appendNamedTests(
    arena: std.mem.Allocator,
    out: *std.ArrayList(QualifiedName),
    prefix: []const u8,
    source: []const u8,
) !void {
    var rest = source;
    var at_line_start = true;
    while (rest.len != 0) {
        if (at_line_start and std.mem.startsWith(u8, rest, "test \"")) {
            const body = rest["test \"".len..];
            const end = std.mem.indexOfScalar(u8, body, '"') orelse return;
            try out.append(arena, try std.mem.concat(arena, u8, &.{ prefix, body[0..end] }));
            rest = body[end..];
            at_line_start = false;
            continue;
        }
        at_line_start = rest[0] == '\n';
        rest = rest[1..];
    }
}

/// How many shards would compile `name` into their binary.
fn claimingShards(name: QualifiedName) usize {
    var claims: usize = 0;
    for (test_shards.shards) |shard| {
        for (shard) |filter| {
            if (std.mem.indexOf(u8, name, filter) != null) {
                claims += 1;
                break;
            }
        }
    }
    return claims;
}

// spec: Development pipeline - Runs the unit-test suite as concurrent shards whose filters claim every named test, including local-first routing regressions, exactly once

// spec: placement/power-routing - power-routing named tests remain assigned to exactly one test shard
test "shard manifest runs every named test exactly once" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var names: std.ArrayList(QualifiedName) = .empty;
    try collectQualifiedNames(arena, &names);
    // A scan that found nothing would make every assertion below vacuous.
    try std.testing.expect(names.items.len > 2000);
    // New serve modules must be assigned explicitly rather than disappearing
    // behind the broad integrity loop when their test-root import first lands.
    try std.testing.expectEqual(@as(usize, 1), claimingShards("serve.warmup.test.startup prioritizes PCB pages over deferred payloads over progress ladders"));
    try std.testing.expectEqual(@as(usize, 1), claimingShards("serve.pcb_derived.test.deferred warm slots are capped and released"));
    try std.testing.expectEqual(@as(usize, 1), claimingShards("serve.dossier_jobs.test.the dossier store admits one compose per system and serves the finished document"));
    try std.testing.expectEqual(@as(usize, 1), claimingShards("shape_sketch.test.outline sketch compiles an ordered line profile"));
    try std.testing.expectEqual(@as(usize, 1), claimingShards("serve.shape_sketch_json.test.outline sketch JSON round trips stable entities and dimensions"));
    try std.testing.expectEqual(@as(usize, 1), claimingShards("main.test.one-shot CLI allocator releases process-lifetime storage in bulk"));

    for (names.items) |name| {
        const claims = claimingShards(name);
        if (claims == 1) continue;
        std.debug.print(
            "src/test_shards.zig: {d} shard(s) claim \"{s}\" (want exactly 1)\n",
            .{ claims, name },
        );
        return error.ShardCoverageBroken;
    }
}

/// The `src/<path>.zig` a shard filter selects from, i.e. the text before
/// `.test.`. Every entry in the manifest has that shape by construction.
fn filterModule(filter: []const u8) ?[]const u8 {
    const end = std.mem.indexOf(u8, filter, ".test.") orelse return null;
    return filter[0..end];
}

/// Reads `src/<module>.zig` and appends its `test "..."` names, qualified.
fn appendModuleTests(
    arena: std.mem.Allocator,
    out: *std.ArrayList(QualifiedName),
    module: []const u8,
) !void {
    const rel = try arena.dupe(u8, module);
    std.mem.replaceScalar(u8, rel, '.', std.fs.path.sep);
    const path = try std.mem.concat(arena, u8, &.{ "src", &.{std.fs.path.sep}, rel, ".zig" });
    const source = try readRepoFile(arena, path);
    const prefix = try std.mem.concat(arena, u8, &.{ module, ".test." });
    try appendNamedTests(arena, out, prefix, source);
}

// THE shard-integrity check, and the reason it is an UNNAMED test block: the
// compiler links an unnamed block into every filtered binary regardless of the
// filters, so this runs once per shard, inside the shard, with that shard's own
// `builtin.test_functions` in hand. A named test could only ever check the one
// shard that happened to own it.
//
// The named tests above prove the manifest partitions the tree. They cannot
// prove the COMPILER agreed: a filter names a test the compiler still drops
// when nothing analyzes its file. That gap is what deleted 49 tests from the
// first sharded build with all eight shards reporting PASS, so the claim is
// verified here against what actually got compiled.
test {
    const shard_env = std.process.Environ.getAlloc(
        std.testing.environ,
        std.testing.allocator,
        "NETLISP_TEST_SHARD",
    ) catch null;
    // Unset: an unsharded binary (`-Dtest-filter=...`, `test-compile`, or a
    // direct `zig test`). Its selection is the caller's business, not ours.
    const shard_text = shard_env orelse return;
    defer std.testing.allocator.free(shard_text);
    const shard_index = try std.fmt.parseUnsigned(usize, shard_text, 10);
    try std.testing.expect(shard_index < test_shards.shards.len);

    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var expected: std.ArrayList(QualifiedName) = .empty;
    try collectShardClaims(arena, shard_index, &expected);

    const compiled = @import("builtin").test_functions;
    for (expected.items) |name| {
        // Only names this shard actually claims: a module split across shards
        // contributes its other prefixes to somebody else.
        if (claimingShardIndex(name) != shard_index) continue;
        for (compiled) |test_fn| {
            if (std.mem.eql(u8, test_fn.name, name)) break;
        } else {
            std.debug.print(
                "shard {d}: manifest claims \"{s}\" but the compiler left it out\n",
                .{ shard_index, name },
            );
            return error.ShardDroppedTest;
        }
    }
}

/// Appends every named test declared by the modules shard `shard_index` draws
/// from. Only that shard's own modules are read — the whole-tree walk belongs
/// to the named coverage test, which runs once rather than once per shard.
fn collectShardClaims(
    arena: std.mem.Allocator,
    shard_index: usize,
    out: *std.ArrayList(QualifiedName),
) !void {
    var seen: std.ArrayList([]const u8) = .empty;
    for (test_shards.shards[shard_index]) |filter| {
        const module = filterModule(filter) orelse return error.MalformedShardFilter;
        for (seen.items) |done| {
            if (std.mem.eql(u8, done, module)) break;
        } else {
            try seen.append(arena, module);
            try appendModuleTests(arena, out, module);
        }
    }
}

/// Index of the single shard whose filters claim `name`, or `shards.len` when
/// none does. Pairs with `claimingShards`, which counts them.
fn claimingShardIndex(name: QualifiedName) usize {
    for (test_shards.shards, 0..) |shard, index| {
        for (shard) |filter| {
            if (std.mem.indexOf(u8, name, filter) != null) return index;
        }
    }
    return test_shards.shards.len;
}

// spec: Development pipeline - Bridges every test-bearing module into the shard import graph so filters alone decide a shard's contents

test "the shard import bridge lists every module whose tests run" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const root_source = try readRepoFile(arena, "src/test_root.zig");
    var names: std.ArrayList(QualifiedName) = .empty;
    try collectQualifiedNames(arena, &names);

    var missing: usize = 0;
    var checked: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        const module = filterModule(name) orelse continue;
        // The root IS the compilation's root file, never an import of itself.
        if (std.mem.eql(u8, module, "test_root")) continue;
        for (checked.items) |done| {
            if (std.mem.eql(u8, done, module)) break;
        } else {
            try checked.append(arena, module);
            const rel = try arena.dupe(u8, module);
            std.mem.replaceScalar(u8, rel, '.', '/');
            const import = try std.mem.concat(arena, u8, &.{ "_ = @import(\"", rel, ".zig\");" });
            if (std.mem.indexOf(u8, root_source, import) != null) continue;
            missing += 1;
            std.debug.print("src/test_root.zig: shard import bridge is missing {s}\n", .{import});
        }
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
}

// spec: Development pipeline - Rejects a shard filter that no longer names a test in the tree

test "every shard filter still names at least one test" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var names: std.ArrayList(QualifiedName) = .empty;
    try collectQualifiedNames(arena, &names);

    for (test_shards.shards) |shard| {
        for (shard) |filter| {
            for (names.items) |name| {
                if (std.mem.indexOf(u8, name, filter) != null) break;
            } else {
                // A dead filter is a shard the compiler leaves empty, which
                // Guardian's runner fails on — but only once the shard is the
                // LAST holder of a filter. Naming it here says which one.
                std.debug.print("src/test_shards.zig: no test matches \"{s}\"\n", .{filter});
                return error.DeadShardFilter;
            }
        }
    }
}

// spec: Development pipeline - Roots unit tests separately from the production executable

test "build uses the dedicated test root for both test binaries" {
    const source = try readRepoFile(std.testing.allocator, "build.zig");
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, "b.path(\"src/test_root.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, source, "b.path(\"src/main.zig\")"));
}

// spec: Development pipeline - Pins every gated full-test invocation with `--seed=1` so an unchanged tree's test run is a cache hit

test "gated full test invocations pin the Zig build seed" {
    const gate = try readRepoFile(std.testing.allocator, "guardian.toml");
    defer std.testing.allocator.free(gate);
    const release = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(release);

    // Zig 0.17's build runner derives the test-runner seed after build.zig has
    // configured the run step. Pinning the top-level build seed is therefore
    // the supported way to keep its generated argv and cache key stable.
    try std.testing.expect(std.mem.indexOf(u8, gate, "zig build --seed=1 test") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        release,
        "\"$ZIG\" build --seed=1 test",
    ) != null);
}

// spec: Development pipeline - Release binaries carry the tag they were built from as a compile-time build identity

test "release workflow stamps the tag into the binary it publishes" {
    const workflow = try readRepoFile(std.testing.allocator, ".github/workflows/release.yml");
    defer std.testing.allocator.free(workflow);
    // The stamp is passed to the build and then asserted on the stripped binary,
    // so a tarball names its tag while a checkout keeps resolving git at runtime.
    try std.testing.expect(std.mem.indexOf(u8, workflow, "\"-Dbuild-id=${GITHUB_REF_NAME}\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "test \"$(\"$bin\" version)\" = \"${GITHUB_REF_NAME}\"") != null);
}

// spec: Development pipeline - Runs full tests and forces the concurrent ReleaseSafe build through the self-hosted backend for one exact commit

test "release preparation starts test and build jobs before waiting" {
    const build_source = try readRepoFile(std.testing.allocator, "build.zig");
    defer std.testing.allocator.free(build_source);
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    const test_start = std.mem.indexOf(u8, source, "start_release_job \"$staging/test.status\"").?;
    const build_start = std.mem.indexOf(u8, source, "start_release_job \"$staging/build.status\"").?;
    const first_wait = std.mem.indexOf(u8, source, "wait \"$test_pid\"").?;
    try std.testing.expect(test_start < build_start);
    try std.testing.expect(build_start < first_wait);
    try std.testing.expect(std.mem.indexOf(u8, source, "-Doptimize=safe") != null);
    // Default-off `-Dllvm`: every optimized build, the release included, is
    // emitted by the self-hosted backend unless a human asks for LLVM.
    try std.testing.expect(std.mem.indexOf(
        u8,
        build_source,
        ".use_llvm = if (use_llvm) true else if (optimize == .debug) null else false,",
    ) != null);
    // Nothing in the release path opts into LLVM.
    try std.testing.expect(std.mem.indexOf(u8, source, "-Dllvm") == null);
}

// spec: Web Server - Release preparation waits for a stable quiet-host window before PCB-editor timing, retries timing-budget misses after contention clears, and never retries renderer or infrastructure failures
test "release editor timing waits for a quiet host and retries only budget misses" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    const readiness = try readRepoFile(std.testing.allocator, "scripts/perf_host_idle.js");
    defer std.testing.allocator.free(readiness);

    const wait = std.mem.indexOf(u8, source, "node scripts/perf_host_idle.js --wait").?;
    const measure = std.mem.indexOf(u8, source, "node scripts/pcb_editor_perf/run.js").?;
    try std.testing.expect(wait < measure);
    try std.testing.expect(std.mem.indexOf(u8, source, "NETLISP_EDITOR_PERF_ATTEMPTS:-3") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "grep -q 'PCB editor zoom regression:'") != null);
    try std.testing.expect(std.mem.indexOf(u8, readiness, "stableSamples") != null);
    try std.testing.expect(std.mem.indexOf(u8, readiness, "sample.busyPct > config.maxBusyPct") != null);
    try std.testing.expect(std.mem.indexOf(u8, readiness, "sample.runnable > config.maxRunnable") != null);
}

// spec: Development pipeline - Cancels the complete concurrent ReleaseSafe process group as soon as full Debug tests fail

test "failed release tests stop the complete build process group" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    const test_wait = std.mem.indexOf(u8, source, "wait \"$test_pid\"").?;
    const cancel = std.mem.indexOf(u8, source, "cancel_release_job \"$build_pid\"").?;
    const build_wait = std.mem.indexOf(u8, source, "wait \"$build_pid\"").?;
    try std.testing.expect(test_wait < cancel);
    try std.testing.expect(cancel < build_wait);
    try std.testing.expect(std.mem.indexOf(u8, source, "setsid bash -c") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "kill -TERM -- \"-$pid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "kill -KILL -- \"-$pid\"") != null);
}

// spec: Development pipeline - Selects a bounded reverse-dependency Debug subset from the Git diff, always includes boundary smoke tests, then analyzes the whole suite without narrowing the release gate

test "affected-test development tier is conservative and cannot narrow release verification" {
    const build = try readRepoFile(std.testing.allocator, "build.zig");
    defer std.testing.allocator.free(build);
    const selector = try readRepoFile(std.testing.allocator, "scripts/test_affected.py");
    defer std.testing.allocator.free(selector);
    const release = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(release);

    try std.testing.expect(std.mem.indexOf(u8, build, "b.step(\"test-affected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, build, "scripts/test_affected_test.py") != null);
    try std.testing.expect(std.mem.indexOf(u8, selector, "bounded_reverse_closure") != null);
    try std.testing.expect(std.mem.indexOf(u8, selector, "ALWAYS_FILTERS") != null);
    try std.testing.expect(std.mem.indexOf(u8, selector, "test-compile") != null);
    try std.testing.expect(std.mem.indexOf(u8, selector, "MAX_FILTERS") != null);
    try std.testing.expect(std.mem.indexOf(u8, release, "test-affected") == null);
}

// spec: Development pipeline - Strips only the deployment ReleaseSafe executable while internal Debug artifacts keep symbols

test "only the production optimization mode strips the application" {
    const source = try readRepoFile(std.testing.allocator, "build.zig");
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "exe_mod.strip = optimize == .safe;") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "gitShortHash") == null);
    // The only compile-time identity is the explicit, default-less `-Dbuild-id`
    // the release workflow passes; nothing derives a stamp from git at build time.
    try std.testing.expect(std.mem.indexOf(u8, source, "build_options.addOption(?[]const u8, \"build_id\", build_id_opt);") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "b.option([]const u8, \"build-id\"") != null);
}

// spec: Development pipeline - Verifies the self-hosted production ELF has no debug or symbol-table sections before publication

test "release preparation strips and inspects the production ELF" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "\"$STRIP\" --strip-all \"$staging/install/bin/netlisp\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "\"$READELF\" -S \"$staging/install/bin/netlisp\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "\\.(debug_|symtab)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "failed to produce a stripped production executable") != null);
}

// spec: Development pipeline - Records the source tree hash alongside every candidate it publishes

test "release preparation stamps the built tree into both publication paths" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "HEAD_TREE=\"$(git rev-parse \"HEAD^{tree}\")\"") != null);
    // The tree file is what another commit adopts a candidate by, so BOTH the
    // full build and the adoption below have to write it.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, ">\"$staging/tree\""));
}

// spec: Development pipeline - Binds release candidates and caches to the exact compiler binary, not only its reported version

test "release preparation fingerprints the compiler binary" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(
        u8,
        source,
        "ZIG_SHA256=\"$(sha256sum \"$ZIG\"",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, source, ">\"$staging/compiler-sha256\""),
    );
    try std.testing.expect(std.mem.indexOf(u8, source, "-zig-$ZIG_SHA256") != null);
}

// spec: Development pipeline - Rejects production preparation and deployment unless the PATH compiler reports the version pinned in .zigversion

test "release and deploy require the pinned toolchain from PATH" {
    const pinned = try readRepoFile(std.testing.allocator, ".zigversion");
    defer std.testing.allocator.free(pinned);
    const prepare = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(prepare);
    const deploy = try readRepoFile(std.testing.allocator, ".githooks/deploy-prod.sh");
    defer std.testing.allocator.free(deploy);

    for ([_][]const u8{ prepare, deploy }) |source| {
        // One compiler, one pin: PATH by default, `.zigversion` as the only
        // source of the required version, and a loud stop when they disagree.
        try std.testing.expect(std.mem.indexOf(u8, source, "ZIG=\"${ZIG:-zig}\"") != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            source,
            "REQUIRED_ZIG=\"$(tr -d '[:space:]' <\"$TOP/.zigversion\")\"",
        ) != null);
        try std.testing.expect(std.mem.indexOf(
            u8,
            source,
            "if [ \"$ZIG_VERSION\" != \"$REQUIRED_ZIG\" ]; then",
        ) != null);
        // No private compiler may come back: neither a hardcoded version
        // string nor a home-directory toolchain path belongs in these scripts.
        try std.testing.expect(std.mem.indexOf(u8, source, std.mem.trim(u8, pinned, " \t\r\n")) == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "zig-toolchains") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, "REQUIRED_ZIG_SHA256") == null);
    }
    // The candidate still records WHICH binary emitted it, so a same-version
    // rebuild by another compiler is never adopted as this one's artifact.
    try std.testing.expect(std.mem.indexOf(
        u8,
        deploy,
        "cat \"$candidate/compiler-sha256\"",
    ) != null);
}

// spec: Development pipeline - Carries an exact runtime build ID and artifact policy with every release candidate

test "release preparation stamps runtime identity into both publication paths" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, ">\"$staging/build-id\""));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, source, ">\"$staging/artifact-policy\""));
    try std.testing.expect(std.mem.indexOf(u8, source, "ARTIFACT_POLICY=\"release-safe-stripped-v1\"") != null);
}

// spec: Development pipeline - Adopts an already-verified candidate for an identical tree instead of rebuilding

test "tree adoption runs after the exact-commit hit and before any build work" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    const exact_hit = std.mem.indexOf(u8, source, "already has a verified candidate").?;
    const adopt = std.mem.indexOf(u8, source, "if adopt_candidate \"$adopt_source\"; then").?;
    const gate = std.mem.indexOf(u8, source, "running the whole-tree Guardian gate").?;
    const full = std.mem.indexOf(u8, source, "starting full tests and ReleaseSafe build").?;
    try std.testing.expect(exact_hit < adopt);
    try std.testing.expect(adopt < gate);
    try std.testing.expect(gate < full);
    try std.testing.expect(std.mem.indexOf(u8, source, "adopted verified candidate for identical tree") != null);
}

// spec: Development pipeline - Adopts only a candidate carrying its verification marker and a passing checksum, and otherwise falls back to the full build

test "tree adoption demands the verified marker and a passing checksum" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    const start = std.mem.indexOf(u8, source, "candidate_tree_verified() {").?;
    const body = source[start..std.mem.indexOfPos(u8, source, start, "\n}\n").?];
    try std.testing.expect(std.mem.indexOf(u8, body, "\"$(cat \"$dir/tree\")\" = \"$HEAD_TREE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "[ -f \"$dir/verified\" ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ARTIFACT_POLICY") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "sha256sum --check --status netlisp.sha256") != null);
    // No match, or an adoption that cannot complete, builds everything instead.
    try std.testing.expect(std.mem.indexOf(u8, source, "falling back to a full build") != null);
}

// spec: Development pipeline - Deploys only a checksum-verified candidate for the exact main commit

test "deployment validates candidate identity and checksum before install" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/deploy-prod.sh");
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "cat \"$candidate/commit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "cat \"$candidate/build-id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "ARTIFACT_POLICY") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "[ -f \"$candidate/verified\" ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "sha256sum --check --status") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "verified candidate installed") != null);
}

// spec: Development pipeline - A failed test or build keeps its grouped status and full logs without publishing a candidate

test "release failure groups statuses and preserves logs outside candidate storage" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "verification failed:") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "full logs kept at") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "mv \"$staging\" \"$failed\"") != null);
}

// spec: Development pipeline - An absent candidate on main is prepared before the running service is restarted

test "deploy prepares a missing candidate before restart" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/deploy-prod.sh");
    defer std.testing.allocator.free(source);
    const prepare = std.mem.indexOf(u8, source, "prepare-release.sh").?;
    const restart = std.mem.indexOf(u8, source, "systemctl --user restart").?;
    try std.testing.expect(prepare < restart);
}

// spec: Development pipeline - An unhealthy new process rolls back to the last health-checked binary

test "deploy retains health checked rollback after candidate installation" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/deploy-prod.sh");
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "health check FAILED") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "restoring last known-good binary") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "deploy-last-hash") != null);
}

// spec: Development pipeline - Restores the runtime build ID paired with the last health-checked binary during rollback

test "deploy keeps rollback binary and runtime identity paired" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/deploy-prod.sh");
    defer std.testing.allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "GOOD_ID=\"$TOP/.git/deploy-lastgood-id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "DEPLOY_ID=\"$TOP/.git/netlisp-deploy-id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "printf '%s\\n' \"$candidate_build_id\" >\"$GOOD_ID.tmp\"") != null);
    const restore_binary = std.mem.indexOf(u8, source, "cp -f \"$GOOD\" \"$BIN.rollback.tmp\"").?;
    const restore_identity = std.mem.lastIndexOf(u8, source, "restore_good_build_id").?;
    const restart = std.mem.lastIndexOf(u8, source, "systemctl --user restart \"$SERVICE\"").?;
    try std.testing.expect(restore_binary < restore_identity);
    try std.testing.expect(restore_identity < restart);
}

// spec: Development pipeline - A healthy deploy refreshes the design-agent folder's binary and runtime build id

test "deploy refreshes the design-agent folder binary on a healthy install" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/deploy-prod.sh");
    defer std.testing.allocator.free(source);
    // The tracked design-folder launcher materializes this binary; the deploy
    // pre-warms it and writes the paired netlisp commit into the designs repo's git dir.
    try std.testing.expect(std.mem.indexOf(u8, source, "projects/designs/.netlisp-bin/netlisp") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "projects/designs/.git/netlisp-deploy-id") != null);
    // Refreshing must happen only on the HEALTHY path (before the rollback branch),
    // never when the new build failed its health check.
    const refresh = std.mem.indexOf(u8, source, "projects/designs/.netlisp-bin/netlisp").?;
    const rollback = std.mem.indexOf(u8, source, "unhealthy: roll back").?;
    try std.testing.expect(refresh < rollback);
    // It must be best-effort — a failure to refresh must never fail the deploy.
    try std.testing.expect(std.mem.indexOf(u8, source, "WARN: could not refresh projects/designs/.netlisp-bin/netlisp") != null);
}

// spec: Development pipeline - Serializes heavy gates behind one machine-wide lock with an environment bypass

test "gate wrapper waits on one lock and honours the bypass before locking" {
    const source = try readRepoFile(std.testing.allocator, "scripts/gate.sh");
    defer std.testing.allocator.free(source);
    // The bypass has to be decided before the lock file is ever opened.
    const bypass = std.mem.indexOf(u8, source, "\"${NETLISP_GATE_SERIALIZE:-1}\" = \"0\"").?;
    const open_lock = std.mem.indexOf(u8, source, "exec 9>\"$lock\"").?;
    const acquire = std.mem.indexOf(u8, source, "flock -w \"$wait_secs\" 9").?;
    try std.testing.expect(bypass < open_lock);
    try std.testing.expect(open_lock < acquire);
    // Defaults, and the exec that hands the held lock to the gated command.
    try std.testing.expect(std.mem.indexOf(u8, source, "NETLISP_GATE_LOCK:-/tmp/netlisp-gate.lock") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "NETLISP_GATE_WAIT:-5400") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "export NETLISP_GATE_HELD=\"$lock\"") != null);
    try std.testing.expect(std.mem.lastIndexOf(u8, source, "exec \"$@\"").? > acquire);
}

// spec: Development pipeline - Prepares a release under that gate lock without re-entering it

test "release preparation re-execs under the gate lock exactly once" {
    const source = try readRepoFile(std.testing.allocator, ".githooks/prepare-release.sh");
    defer std.testing.allocator.free(source);
    const reexec = std.mem.indexOf(u8, source, "exec \"$TOP/scripts/gate.sh\"").?;
    // Guarded on both the bypass and the marker gate.sh exports, so a script
    // already holding the lock runs its body instead of queueing behind itself.
    const guard = std.mem.indexOf(u8, source, "[ -z \"${NETLISP_GATE_HELD:-}\" ]").?;
    try std.testing.expect(guard < reexec);
    try std.testing.expect(std.mem.indexOf(u8, source, "\"${NETLISP_GATE_SERIALIZE:-1}\" != \"0\"").? < reexec);
    // The re-exec precedes the body, so the whole verification runs under the
    // lock; the internal test/build concurrency below it is untouched.
    try std.testing.expect(reexec < std.mem.indexOf(u8, source, "start_release_job \"$staging/test.status\"").?);
}
