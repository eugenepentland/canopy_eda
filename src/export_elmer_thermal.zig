//! Elmer FEM export for the board thermal screening model.
//!
//! The exporter deliberately carries the built-in model's normalized cell
//! coefficients into a separate finite-element discretization. It is a
//! numerical cross-check of the board-spreading solve, not a claim that the
//! screening constants are independently validated material data.

const std = @import("std");
const json_writer = @import("json_writer.zig");
const thermal_field = @import("placement/thermal_field.zig");

const exporter_version = "1.1.0";
/// ASCII VTU written by the generated ResultOutput solver.
pub const result_filename = "mesh/elmer_result_t0001.vtu";

/// One resolved board and its built-in answer for the exported cooling rung.
pub const Input = struct {
    design_name: []const u8,
    layout_name: []const u8 = "",
    ambient_c: f64 = 25.0,
    sheet: thermal_field.Sheet,
    model: thermal_field.Discretized,
    solver_inputs: thermal_field.Inputs,
    builtin: thermal_field.ScenarioResult,
};

/// Complete contents of a portable Elmer case directory.
pub const Artifact = struct {
    mesh_header: []const u8,
    mesh_nodes: []const u8,
    mesh_elements: []const u8,
    mesh_boundary: []const u8,
    sif: []const u8,
    manifest: []const u8,
    readme: []const u8,
};

const Combo = struct {
    material: u32,
    force: u32,
};

const Groups = struct {
    material_by_cell: []u32,
    force_by_cell: []u32,
    top_boundary_by_cell: []u32,
    bottom_boundary_by_cell: []u32,
    body_by_cell: []u32,
    materials: []f64,
    forces: []f64,
    boundaries: []f64,
    bodies: []Combo,
};

const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{
    InvalidModel,
    InvalidResult,
};

/// Build Elmer's native mesh, solver input, and audit metadata in memory.
pub fn build(alloc: std.mem.Allocator, input: Input) Error!Artifact {
    try validate(input);
    const groups = try groupCells(alloc, input.model);
    return .{
        .mesh_header = try writeHeader(alloc, input.model),
        .mesh_nodes = try writeNodes(alloc, input.model),
        .mesh_elements = try writeElements(alloc, input.model, groups),
        .mesh_boundary = try writeBoundary(alloc, input.model, groups),
        .sif = try writeSif(alloc, input, groups),
        .manifest = try writeManifest(alloc, input, groups),
        .readme = try writeReadme(alloc, input),
    };
}

fn validate(input: Input) error{InvalidModel}!void {
    if (input.model.shape.cols == 0 or input.model.shape.rows == 0) return error.InvalidModel;
    if (input.model.shape.cols > thermal_field.max_cells_axis or input.model.shape.rows > thermal_field.max_cells_axis) return error.InvalidModel;
    const n = input.model.shape.cols * input.model.shape.rows;
    if (input.model.conductivity_w_mk.len != n) return error.InvalidModel;
    if (input.model.top_face_h_w_m2k.len != n) return error.InvalidModel;
    if (input.model.bottom_face_h_w_m2k.len != n) return error.InvalidModel;
    if (input.model.heat_source_w_m3.len != n) return error.InvalidModel;
    if (input.model.active.len != 0 and input.model.active.len != n) return error.InvalidModel;
    if (activeCellCount(input.model) == 0) return error.InvalidModel;
    if (!(input.model.thickness_m > 0) or !std.math.isFinite(input.model.thickness_m)) return error.InvalidModel;
    if (!std.math.isFinite(input.ambient_c)) return error.InvalidModel;
    for (0..n) |i| {
        if (!(input.model.conductivity_w_mk[i] > 0) or !std.math.isFinite(input.model.conductivity_w_mk[i])) return error.InvalidModel;
        if (input.model.top_face_h_w_m2k[i] < 0 or !std.math.isFinite(input.model.top_face_h_w_m2k[i])) return error.InvalidModel;
        if (input.model.bottom_face_h_w_m2k[i] < 0 or !std.math.isFinite(input.model.bottom_face_h_w_m2k[i])) return error.InvalidModel;
        if (input.model.heat_source_w_m3[i] < 0 or !std.math.isFinite(input.model.heat_source_w_m3[i])) return error.InvalidModel;
    }
}

fn groupCells(alloc: std.mem.Allocator, model: thermal_field.Discretized) std.mem.Allocator.Error!Groups {
    const n = model.shape.cols * model.shape.rows;
    const material_by_cell = try alloc.alloc(u32, n);
    const force_by_cell = try alloc.alloc(u32, n);
    const top_boundary_by_cell = try alloc.alloc(u32, n);
    const bottom_boundary_by_cell = try alloc.alloc(u32, n);
    const body_by_cell = try alloc.alloc(u32, n);
    const materials = try alloc.alloc(f64, n);
    const forces = try alloc.alloc(f64, n);
    const boundaries = try alloc.alloc(f64, 2 * n);
    const bodies = try alloc.alloc(Combo, n);
    @memset(material_by_cell, 0);
    @memset(force_by_cell, 0);
    @memset(top_boundary_by_cell, 0);
    @memset(bottom_boundary_by_cell, 0);
    @memset(body_by_cell, 0);
    var material_count: usize = 0;
    var force_count: usize = 0;
    var boundary_count: usize = 0;
    var body_count: usize = 0;
    for (0..n) |i| {
        if (!activeCell(model, i)) continue;
        material_by_cell[i] = internValue(materials, &material_count, model.conductivity_w_mk[i], false);
        force_by_cell[i] = internValue(forces, &force_count, model.heat_source_w_m3[i], true);
        top_boundary_by_cell[i] = internValue(boundaries, &boundary_count, model.top_face_h_w_m2k[i], false);
        bottom_boundary_by_cell[i] = internValue(boundaries, &boundary_count, model.bottom_face_h_w_m2k[i], false);
        const combo = Combo{ .material = material_by_cell[i], .force = force_by_cell[i] };
        body_by_cell[i] = internCombo(bodies, &body_count, combo);
    }
    return .{
        .material_by_cell = material_by_cell,
        .force_by_cell = force_by_cell,
        .top_boundary_by_cell = top_boundary_by_cell,
        .bottom_boundary_by_cell = bottom_boundary_by_cell,
        .body_by_cell = body_by_cell,
        .materials = materials[0..material_count],
        .forces = forces[0..force_count],
        .boundaries = boundaries[0..boundary_count],
        .bodies = bodies[0..body_count],
    };
}

fn activeCell(model: thermal_field.Discretized, i: usize) bool {
    return model.active.len == 0 or model.active[i] != 0;
}

fn activeCellCount(model: thermal_field.Discretized) usize {
    if (model.active.len == 0) return model.shape.cols * model.shape.rows;
    var count: usize = 0;
    for (model.active) |active| if (active != 0) {
        count += 1;
    };
    return count;
}

fn internValue(values: []f64, count: *usize, value: f64, zero_is_none: bool) u32 {
    if (zero_is_none and value == 0) return 0;
    for (values[0..count.*], 0..) |existing, i| {
        if (existing == value) return @intCast(i + 1);
    }
    values[count.*] = value;
    count.* += 1;
    return @intCast(count.*);
}

fn internCombo(values: []Combo, count: *usize, value: Combo) u32 {
    for (values[0..count.*], 0..) |existing, i| {
        if (existing.material == value.material and existing.force == value.force) return @intCast(i + 1);
    }
    values[count.*] = value;
    count.* += 1;
    return @intCast(count.*);
}

fn writeHeader(alloc: std.mem.Allocator, model: thermal_field.Discretized) Error![]const u8 {
    const elements = activeCellCount(model);
    const nodes = (model.shape.cols + 1) * (model.shape.rows + 1) * 2;
    const boundaries = elements * 2;
    return std.fmt.allocPrint(alloc, "{d} {d} {d}\n2\n404 {d}\n808 {d}\n", .{
        nodes, elements, boundaries, boundaries, elements,
    });
}

fn nodeId(shape: thermal_field.GridShape, z: usize, row: usize, col: usize) usize {
    return z * (shape.rows + 1) * (shape.cols + 1) + row * (shape.cols + 1) + col + 1;
}

fn writeNodes(alloc: std.mem.Allocator, model: thermal_field.Discretized) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    const cell_m = model.shape.cell_mm * 1.0e-3;
    const x0 = model.shape.origin_x_mm * 1.0e-3;
    const y0 = model.shape.origin_y_mm * 1.0e-3;
    for (0..2) |z| {
        for (0..model.shape.rows + 1) |row| {
            for (0..model.shape.cols + 1) |col| {
                try w.print("{d} -1 {d} {d} {d}\n", .{
                    nodeId(model.shape, z, row, col),
                    x0 + @as(f64, @floatFromInt(col)) * cell_m,
                    y0 + @as(f64, @floatFromInt(row)) * cell_m,
                    @as(f64, @floatFromInt(z)) * model.thickness_m,
                });
            }
        }
    }
    return out.toOwnedSlice();
}

fn writeElements(alloc: std.mem.Allocator, model: thermal_field.Discretized, groups: Groups) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    var id: usize = 1;
    for (0..model.shape.rows) |row| {
        for (0..model.shape.cols) |col| {
            const i = row * model.shape.cols + col;
            if (!activeCell(model, i)) continue;
            try w.print("{d} {d} 808 {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
                id,
                groups.body_by_cell[i],
                nodeId(model.shape, 0, row, col),
                nodeId(model.shape, 0, row, col + 1),
                nodeId(model.shape, 0, row + 1, col + 1),
                nodeId(model.shape, 0, row + 1, col),
                nodeId(model.shape, 1, row, col),
                nodeId(model.shape, 1, row, col + 1),
                nodeId(model.shape, 1, row + 1, col + 1),
                nodeId(model.shape, 1, row + 1, col),
            });
            id += 1;
        }
    }
    return out.toOwnedSlice();
}

fn writeBoundary(alloc: std.mem.Allocator, model: thermal_field.Discretized, groups: Groups) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    var boundary_id: usize = 1;
    var parent: usize = 1;
    for (0..model.shape.rows) |row| {
        for (0..model.shape.cols) |col| {
            const i = row * model.shape.cols + col;
            if (!activeCell(model, i)) continue;
            const bottom_bc = groups.bottom_boundary_by_cell[i];
            const top_bc = groups.top_boundary_by_cell[i];
            try w.print("{d} {d} {d} 0 404 {d} {d} {d} {d}\n", .{
                boundary_id,                          bottom_bc,                            parent,
                nodeId(model.shape, 0, row, col),     nodeId(model.shape, 0, row + 1, col), nodeId(model.shape, 0, row + 1, col + 1),
                nodeId(model.shape, 0, row, col + 1),
            });
            boundary_id += 1;
            try w.print("{d} {d} {d} 0 404 {d} {d} {d} {d}\n", .{
                boundary_id,                          top_bc,                               parent,
                nodeId(model.shape, 1, row, col),     nodeId(model.shape, 1, row, col + 1), nodeId(model.shape, 1, row + 1, col + 1),
                nodeId(model.shape, 1, row + 1, col),
            });
            boundary_id += 1;
            parent += 1;
        }
    }
    return out.toOwnedSlice();
}

fn writeSif(alloc: std.mem.Allocator, input: Input, groups: Groups) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.writeAll(
        "Header\n  CHECK KEYWORDS Warn\n  Mesh DB \".\" \"mesh\"\nEnd\n\n" ++
            "Simulation\n  Coordinate System = Cartesian 3D\n  Coordinate Mapping(3) = 1 2 3\n" ++
            "  Simulation Type = Steady State\n  Steady State Max Iterations = 1\n  Output Intervals = 1\n" ++
            "  Solver Input File = case.sif\n  Post File = elmer_result.ep\nEnd\n\n" ++
            "Equation 1\n  Name = \"Steady board heat\"\n  Active Solvers(2) = 1 2\nEnd\n\n" ++
            "Solver 1\n  Equation = Heat Equation\n  Procedure = \"HeatSolve\" \"HeatSolver\"\n" ++
            "  Variable = Temperature\n  Variable DOFs = 1\n  Linear System Solver = Iterative\n" ++
            "  Linear System Iterative Method = BiCGStab\n  Linear System Preconditioning = ILU0\n" ++
            "  Linear System Max Iterations = 10000\n  Linear System Convergence Tolerance = 1.0e-11\n" ++
            "  Steady State Convergence Tolerance = 1.0e-10\nEnd\n\n" ++
            "Solver 2\n  Exec Solver = After Simulation\n  Procedure = \"ResultOutputSolve\" \"ResultOutputSolver\"\n" ++
            "  Output File Name = elmer_result\n  Vtu Format = Logical True\n  Ascii Output = Logical True\n" ++
            "  Save Geometry IDs = Logical True\nEnd\n\n",
    );
    for (groups.bodies, 0..) |body, i| {
        try w.print("Body {d}\n  Target Bodies(1) = {d}\n  Equation = 1\n  Material = {d}\n", .{ i + 1, i + 1, body.material });
        if (body.force != 0) try w.print("  Body Force = {d}\n", .{body.force});
        try w.writeAll("  Initial Condition = 1\nEnd\n\n");
    }
    for (groups.materials, 0..) |conductivity, i| {
        try w.print("Material {d}\n  Name = \"Equivalent board sheet {d}\"\n  Density = 1.0\n  Heat Conductivity = {d}\nEnd\n\n", .{ i + 1, i + 1, conductivity });
    }
    for (groups.forces, 0..) |source, i| {
        try w.print("Body Force {d}\n  Name = \"Component heat group {d}\"\n  Heat Source = {d}\nEnd\n\n", .{ i + 1, i + 1, source });
    }
    try w.print("Initial Condition 1\n  Temperature = {d}\nEnd\n\n", .{input.ambient_c});
    for (groups.boundaries, 0..) |h, i| {
        try w.print("Boundary Condition {d}\n  Name = \"Board faces h={d} W/m2K\"\n  Target Boundaries(1) = {d}\n  Heat Transfer Coefficient = {d}\n  External Temperature = {d}\nEnd\n\n", .{
            i + 1, h, i + 1, h, input.ambient_c,
        });
    }
    return out.toOwnedSlice();
}

fn writeManifest(alloc: std.mem.Allocator, input: Input, groups: Groups) Error![]const u8 {
    const sheet = input.sheet;
    const shape = input.model.shape;
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.writeAll("{\n  \"schema\":\"netlisp-elmer-thermal\",\n  \"schemaVersion\":\"1.0\",\n  \"exporterVersion\":");
    try json_writer.writeString(w, exporter_version);
    try w.writeAll(",\n  \"design\":");
    try json_writer.writeString(w, input.design_name);
    try w.writeAll(",\n  \"layout\":");
    if (input.layout_name.len == 0) try w.writeAll("null") else try json_writer.writeString(w, input.layout_name);
    const scenario = input.builtin.scenario;
    try w.print(",\n  \"scenario\":{{\"name\":\"{s}\",\"ambientC\":{d},\"airSpeedMps\":", .{ @tagName(scenario), input.ambient_c });
    const speed = if (scenario == .fan) thermal_field.fanVelocity(input.solver_inputs.cooling.fan) else airSpeedMps(scenario);
    if (speed) |value| try w.print("{d}", .{value}) else try w.writeAll("null");
    try w.print(",\"stillAir\":{s},\"faceFilmWm2K\":", .{if (scenario == .natural or scenario == .heatsink) "true" else "false"});
    if (scenario == .fan) try w.writeAll("null") else try w.print("{d}", .{scenario.filmCoefficient()});
    try w.writeAll(",\"edgeCondition\":\"adiabatic\"},\n");
    if (scenario == .heatsink) {
        const hs = input.solver_inputs.cooling.heatsink;
        const ref_des = appliedHeatsinkRef(input);
        const theta_sa = thermal_field.sinkToAmbient(hs);
        const fin_count = thermal_field.finCount(hs.geometry);
        try w.writeAll("  \"heatsink\":{\"ref\":");
        try json_writer.writeString(w, ref_des);
        try w.print(",\"contact\":\"{s}\",\"physicalBoardFace\":\"{s}\",\"material\":\"{s}\",\"thetaSaCPerW\":{d},\"geometryMm\":{{\"width\":{d},\"length\":{d},\"base\":{d},\"finHeight\":{d},\"finThickness\":{d},\"finGap\":{d},\"finAxis\":\"{s}\",\"finCount\":{d}}},\"contactRectMm\":", .{
            @tagName(hs.side),      physicalSinkFace(input, ref_des), @tagName(hs.material),
            theta_sa,               hs.geometry.width_mm,             hs.geometry.length_mm,
            hs.geometry.base_mm,    hs.geometry.fin_height_mm,        hs.geometry.fin_thickness_mm,
            hs.geometry.fin_gap_mm, @tagName(hs.geometry.fin_axis),   fin_count,
        });
        if (hs.contact) |rect| {
            try w.print("[{d},{d},{d},{d}]", .{ rect.x_mm, rect.y_mm, rect.w_mm, rect.h_mm });
        } else try w.writeAll("null");
        try w.print(",\"pad\":{{\"thicknessMm\":{d},\"conductivityWmK\":{d}}}}},\n", .{
            hs.pad.thickness_mm, hs.pad.conductivity_w_mk,
        });
    } else {
        try w.writeAll("  \"heatsink\":null,\n");
    }
    if (scenario == .fan) {
        const fan = input.solver_inputs.cooling.fan;
        const rect = fan.footprint orelse thermal_field.BoardRect{ .x_mm = 0, .y_mm = 0, .w_mm = 0, .h_mm = 0 };
        try w.writeAll("  \"fan\":{\"model\":");
        try json_writer.writeString(w, fan.model);
        try w.print(",\"face\":\"{s}\",\"footprintMm\":[{d},{d},{d},{d}],\"distanceMm\":{d},\"freeAirFlowM3s\":{d},\"maxStaticPressurePa\":{d},\"operatingFlowFraction\":{d},\"operatingFlowM3s\":{d},\"estimatedPressurePa\":{d},\"velocityAtBoardMps\":{d}}},\n", .{
            @tagName(fan.face),     rect.x_mm,                  rect.y_mm,                   rect.w_mm,           rect.h_mm,               fan.distance_mm,
            fan.free_air_flow_m3_s, fan.max_static_pressure_pa, fan.operating_flow_fraction, fan.operatingFlow(), fan.estimatedPressure(), thermal_field.fanVelocity(fan),
        });
    } else {
        try w.writeAll("  \"fan\":null,\n");
    }
    try w.print("  \"board\":{{\"xMm\":{d},\"yMm\":{d},\"widthMm\":{d},\"heightMm\":{d},\"modeledThicknessM\":{d}}},\n", .{
        input.solver_inputs.board.x_mm,
        input.solver_inputs.board.y_mm,
        input.solver_inputs.board.w_mm,
        input.solver_inputs.board.h_mm,
        input.model.thickness_m,
    });
    try w.print("  \"normalizedRules\":{{\"spreaderLayers\":{d},\"outerCopperM\":{d},\"innerPlaneCopperM\":{d},\"laminateM\":{d},\"componentTransferM\":{d},\"bareFaceFilmWm2K\":{d},\"coveredFaceFraction\":0.4}},\n", .{
        input.solver_inputs.spreader_layers, sheet.outer_cu_m, sheet.inner_cu_m, sheet.laminate_m, sheet.transfer_m, scenario.filmCoefficient(),
    });
    try w.print("  \"mesh\":{{\"format\":\"Elmer native\",\"elementType\":808,\"boundaryType\":404,\"columns\":{d},\"rows\":{d},\"activeElements\":{d},\"cellMm\":{d},\"modeledWidthMm\":{d},\"modeledHeightMm\":{d},\"elementsThroughThickness\":1,\"materialGroups\":{d},\"heatSourceGroups\":{d},\"faceBoundaryGroups\":{d}}},\n", .{
        shape.cols,
        shape.rows,
        activeCellCount(input.model),
        shape.cell_mm,
        @as(f64, @floatFromInt(shape.cols)) * shape.cell_mm,
        @as(f64, @floatFromInt(shape.rows)) * shape.cell_mm,
        groups.materials.len,
        groups.forces.len,
        groups.boundaries.len,
    });
    try w.writeAll("  \"parts\":[\n");
    var first = true;
    for (input.solver_inputs.parts) |part| {
        const box = part.mount.box orelse continue;
        if (!first) try w.writeAll(",\n");
        first = false;
        try w.writeAll("    {\"ref\":");
        try json_writer.writeString(w, part.ref_des);
        try w.print(",\"watts\":{d},\"side\":\"{s}\",\"boxMm\":[{d},{d},{d},{d}],\"thermalVias\":{d},\"viaDrillMm\":{d}}}", .{
            part.watts,              @tagName(part.mount.side), box.x_mm, box.y_mm, box.w_mm, box.h_mm,
            part.mount.thermal_vias, part.mount.via_drill_mm,
        });
    }
    try w.writeAll("\n  ],\n  \"interpretation\":\"Independent FEM discretization of the same screening coefficients; use the comparison delta to detect numerical/model-projection disagreement, not as material validation.\"\n}\n");
    return out.toOwnedSlice();
}

fn writeReadme(alloc: std.mem.Allocator, input: Input) Error![]const u8 {
    const cooling = coolingLabel(input.builtin.scenario);
    const sink_assembly = if (input.builtin.scenario == .heatsink or input.builtin.scenario == .fan_heatsink) blk: {
        const hs = input.solver_inputs.cooling.heatsink;
        break :blk try std.fmt.allocPrint(alloc, "\nHeatsink assembly: **{s}** contact on **{s}** at the PCB **{s}** face; {d} x {d} mm **{s}** base, {d} mm base thickness + {d} mm fins ({d} derived fins, {d} mm thick / {d} mm gap), estimated theta-SA {d} C/W, with a {d} mm / {d} W/mK thermal pad.\n", .{
            @tagName(hs.side),            appliedHeatsinkRef(input), physicalSinkFace(input, appliedHeatsinkRef(input)),
            hs.geometry.width_mm,         hs.geometry.length_mm,     @tagName(hs.material),
            hs.geometry.base_mm,          hs.geometry.fin_height_mm, thermal_field.finCount(hs.geometry),
            hs.geometry.fin_thickness_mm, hs.geometry.fin_gap_mm,    thermal_field.sinkToAmbient(hs),
            hs.pad.thickness_mm,          hs.pad.conductivity_w_mk,
        });
    } else "";
    const fan_assembly = if (input.builtin.scenario == .fan or input.builtin.scenario == .fan_heatsink) blk: {
        const fan = input.solver_inputs.cooling.fan;
        break :blk try std.fmt.allocPrint(alloc, "\nFan assembly: **{s}** aimed at the PCB **{s}** face from {d} mm; catalog endpoints {d} m3/s free-air and {d} Pa shutoff, screened at {d:.0}% delivered flow ({d} m3/s, {d:.1} m/s area-average velocity at the board).\n", .{
            fan.model,                  @tagName(fan.face),                fan.distance_mm,     fan.free_air_flow_m3_s,
            fan.max_static_pressure_pa, 100 * fan.operating_flow_fraction, fan.operatingFlow(), thermal_field.fanVelocity(fan),
        });
    } else "";
    const assembly = try std.fmt.allocPrint(alloc, "{s}{s}", .{ sink_assembly, fan_assembly });
    return std.fmt.allocPrint(
        alloc,
        "# {s} — Elmer thermal case\n\n" ++
            "Steady-state cooling at **{d} °C ambient** with **{s}**. Run from this directory with:\n\n" ++
            "```sh\nElmerSolver case.sif\n```\n\n" ++
            "The native mesh is under `mesh/`; results are written to `{s}`. `manifest.json` records the normalized board, stackup, cooling, and component-power rules.\n{s}\n" ++
            "This case extrudes each built-in thermal-grid cell through one board-thickness element. In-plane conductivity, heat generation, and the two-face film loss are projected from the EDA solver cell-for-cell; board edges are adiabatic. It is therefore a finite-element numerical cross-check of the screening model, not an independently calibrated high-fidelity PCB material model.\n",
        .{ input.design_name, input.ambient_c, cooling, result_filename, assembly },
    );
}

fn appliedHeatsinkRef(input: Input) []const u8 {
    if (input.solver_inputs.cooling.heatsink.ref_des.len > 0) return input.solver_inputs.cooling.heatsink.ref_des;
    for (input.builtin.parts) |part| {
        if (part.junction_path != .board) return part.ref_des;
    }
    return "";
}

fn physicalSinkFace(input: Input, ref_des: []const u8) []const u8 {
    if (input.solver_inputs.cooling.heatsink.physical_face) |face| return @tagName(face);
    const part = findPart(input.solver_inputs.parts, ref_des) orelse return "unknown";
    const face = switch (input.solver_inputs.cooling.heatsink.side) {
        .package_top => part.mount.side,
        .board_backside => if (part.mount.side == .top) thermal_field.Side.bottom else thermal_field.Side.top,
    };
    return @tagName(face);
}

fn airSpeedMps(scenario: thermal_field.Scenario) ?f64 {
    return switch (scenario) {
        .natural, .fan, .heatsink, .fan_heatsink => null,
        .airflow_1ms => 1,
        .airflow_2ms => 2,
    };
}

fn coolingLabel(scenario: thermal_field.Scenario) []const u8 {
    return switch (scenario) {
        .natural => "natural still air",
        .fan => "the specified fan",
        .airflow_1ms => "1 m/s airflow",
        .airflow_2ms => "2 m/s airflow",
        .heatsink => "a heatsink",
        .fan_heatsink => "the specified fan and passive heatsink",
    };
}

/// Nodal temperatures recovered from Elmer's result file, indexed by native
/// mesh node id minus one.
pub const ParsedResult = struct {
    temperatures_by_node: []f64,
};

/// Parse the ASCII VTU emitted by the generated case and undo Elmer's node
/// renumbering from the saved point coordinates.
pub fn parseVtu(alloc: std.mem.Allocator, xml: []const u8, model: thermal_field.Discretized) Error!ParsedResult {
    const expected_nodes = (model.shape.cols + 1) * (model.shape.rows + 1) * 2;
    const temp_text = dataArray(xml, "temperature") orelse return error.InvalidResult;
    const temp_values = try parseFloatList(alloc, temp_text);
    defer alloc.free(temp_values);
    if (temp_values.len != expected_nodes) return error.InvalidResult;
    const point_text = dataArrayAfter(xml, "<Points>") orelse return error.InvalidResult;
    const points = try parseFloatList(alloc, point_text);
    defer alloc.free(points);
    if (points.len != expected_nodes * 3) return error.InvalidResult;
    const result = try alloc.alloc(f64, expected_nodes);
    @memset(result, std.math.nan(f64));
    const cell_m = model.shape.cell_mm * 1.0e-3;
    const x0 = model.shape.origin_x_mm * 1.0e-3;
    const y0 = model.shape.origin_y_mm * 1.0e-3;
    for (temp_values, 0..) |value, i| {
        const col_f = std.math.round((points[i * 3] - x0) / cell_m);
        const row_f = std.math.round((points[i * 3 + 1] - y0) / cell_m);
        const z_f = std.math.round(points[i * 3 + 2] / model.thickness_m);
        if (!std.math.isFinite(col_f)) return error.InvalidResult;
        if (!std.math.isFinite(row_f)) return error.InvalidResult;
        if (!std.math.isFinite(z_f)) return error.InvalidResult;
        if (col_f < 0 or col_f > @as(f64, @floatFromInt(model.shape.cols))) return error.InvalidResult;
        if (row_f < 0 or row_f > @as(f64, @floatFromInt(model.shape.rows))) return error.InvalidResult;
        if (z_f < 0 or z_f > 1) return error.InvalidResult;
        const id = nodeId(model.shape, @intFromFloat(z_f), @intFromFloat(row_f), @intFromFloat(col_f));
        result[id - 1] = value;
    }
    for (result) |value| if (!std.math.isFinite(value)) return error.InvalidResult;
    return .{ .temperatures_by_node = result };
}

fn dataArray(xml: []const u8, name: []const u8) ?[]const u8 {
    var needle_buf: [160]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "Name=\"{s}\"", .{name}) catch return null;
    const name_pos = std.mem.indexOf(u8, xml, needle) orelse return null;
    const open_rel = std.mem.indexOfScalar(u8, xml[name_pos..], '>') orelse return null;
    const start = name_pos + open_rel + 1;
    const close_rel = std.mem.indexOf(u8, xml[start..], "</DataArray>") orelse return null;
    return xml[start .. start + close_rel];
}

fn dataArrayAfter(xml: []const u8, marker: []const u8) ?[]const u8 {
    const marker_pos = std.mem.indexOf(u8, xml, marker) orelse return null;
    const array_rel = std.mem.indexOf(u8, xml[marker_pos..], "<DataArray") orelse return null;
    const array_pos = marker_pos + array_rel;
    const open_rel = std.mem.indexOfScalar(u8, xml[array_pos..], '>') orelse return null;
    const start = array_pos + open_rel + 1;
    const close_rel = std.mem.indexOf(u8, xml[start..], "</DataArray>") orelse return null;
    return xml[start .. start + close_rel];
}

fn parseFloatList(alloc: std.mem.Allocator, text: []const u8) Error![]f64 {
    var count: usize = 0;
    var scan = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (scan.next() != null) count += 1;
    const out = try alloc.alloc(f64, count);
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var i: usize = 0;
    while (tokens.next()) |token| : (i += 1) out[i] = std.fmt.parseFloat(f64, token) catch return error.InvalidResult;
    return out;
}

/// One value reported by both solvers and Elmer minus built-in.
pub const Metric = struct {
    builtin_c: f64,
    elmer_c: f64,
    delta_c: f64,
};

/// Side-by-side temperatures for one powered or thermally rated part.
pub const PartComparison = struct {
    ref_des: []const u8,
    watts: f64,
    board: Metric,
    junction: ?Metric,
};

/// Whole-board comparison for one cooling rung, including every placed row.
pub const Comparison = struct {
    scenario: thermal_field.Scenario,
    ambient_c: f64,
    board_max: Metric,
    parts: []const PartComparison,
};

/// Compare Elmer's element-average temperatures with the built-in cell field.
pub fn compare(
    alloc: std.mem.Allocator,
    input: Input,
    parsed: ParsedResult,
) Error!Comparison {
    const shape = input.model.shape;
    const expected_nodes = (shape.cols + 1) * (shape.rows + 1) * 2;
    if (parsed.temperatures_by_node.len != expected_nodes) return error.InvalidResult;
    const cell_t = try alloc.alloc(f64, shape.cols * shape.rows);
    var elmer_max = -std.math.inf(f64);
    for (0..shape.rows) |row| {
        for (0..shape.cols) |col| {
            const cell_i = row * shape.cols + col;
            if (!activeCell(input.model, cell_i)) {
                cell_t[cell_i] = std.math.nan(f64);
                continue;
            }
            var sum: f64 = 0;
            for (0..2) |z| {
                sum += parsed.temperatures_by_node[nodeId(shape, z, row, col) - 1];
                sum += parsed.temperatures_by_node[nodeId(shape, z, row, col + 1) - 1];
                sum += parsed.temperatures_by_node[nodeId(shape, z, row + 1, col + 1) - 1];
                sum += parsed.temperatures_by_node[nodeId(shape, z, row + 1, col) - 1];
            }
            const value = sum / 8.0;
            cell_t[cell_i] = value;
            elmer_max = @max(elmer_max, value);
        }
    }
    const rows = try alloc.alloc(PartComparison, input.builtin.parts.len);
    for (input.builtin.parts, rows) |builtin, *row| {
        const part = findPart(input.solver_inputs.parts, builtin.ref_des) orelse return error.InvalidModel;
        const box = part.mount.box orelse return error.InvalidModel;
        const cells = thermal_field.cellsForBox(shape, box);
        var part_max = -std.math.inf(f64);
        var r = cells.row_lo;
        while (r <= cells.row_hi) : (r += 1) {
            var c = cells.col_lo;
            while (c <= cells.col_hi) : (c += 1) {
                const i = r * shape.cols + c;
                if (activeCell(input.model, i)) part_max = @max(part_max, cell_t[i]);
            }
        }
        const builtin_board = input.ambient_c + builtin.board_rise_c;
        const builtin_junction = if (builtin.tj_rise_c) |rise| input.ambient_c + rise else null;
        const package_uplift = if (builtin.tj_rise_c) |rise| rise - builtin.board_rise_c else null;
        const elmer_junction = if (package_uplift) |rise| part_max + rise else null;
        row.* = .{
            .ref_des = builtin.ref_des,
            .watts = part.watts,
            .board = .{ .builtin_c = builtin_board, .elmer_c = part_max, .delta_c = part_max - builtin_board },
            .junction = if (builtin_junction != null and elmer_junction != null) .{
                .builtin_c = builtin_junction.?,
                .elmer_c = elmer_junction.?,
                .delta_c = elmer_junction.? - builtin_junction.?,
            } else null,
        };
    }
    const builtin_max = input.ambient_c + input.builtin.hotspot.rise_c;
    return .{
        .scenario = input.builtin.scenario,
        .ambient_c = input.ambient_c,
        .board_max = .{ .builtin_c = builtin_max, .elmer_c = elmer_max, .delta_c = elmer_max - builtin_max },
        .parts = rows,
    };
}

fn findPart(parts: []const thermal_field.PartInput, ref_des: []const u8) ?thermal_field.PartInput {
    for (parts) |part| if (std.mem.eql(u8, part.ref_des, ref_des)) return part;
    return null;
}

/// Serialize the machine-readable comparison report.
pub fn comparisonJson(alloc: std.mem.Allocator, comparison: Comparison) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.print("{{\n  \"ambientC\":{d},\n  \"scenario\":\"{s}\",\n  \"board\":{{\"builtinMaxC\":{d},\"elmerMaxC\":{d},\"deltaC\":{d}}},\n  \"parts\":[\n", .{
        comparison.ambient_c, @tagName(comparison.scenario), comparison.board_max.builtin_c, comparison.board_max.elmer_c, comparison.board_max.delta_c,
    });
    for (comparison.parts, 0..) |part, i| {
        if (i > 0) try w.writeAll(",\n");
        try w.writeAll("    {\"ref\":");
        try json_writer.writeString(w, part.ref_des);
        try w.print(",\"watts\":{d},\"builtinBoardC\":{d},\"elmerBoardC\":{d},\"boardDeltaC\":{d},\"builtinJunctionC\":", .{
            part.watts, part.board.builtin_c, part.board.elmer_c, part.board.delta_c,
        });
        if (part.junction) |value| try w.print("{d}", .{value.builtin_c}) else try w.writeAll("null");
        try w.writeAll(",\"elmerJunctionC\":");
        if (part.junction) |value| try w.print("{d}", .{value.elmer_c}) else try w.writeAll("null");
        try w.writeAll(",\"junctionDeltaC\":");
        if (part.junction) |value| try w.print("{d}", .{value.delta_c}) else try w.writeAll("null");
        try w.writeByte('}');
    }
    try w.writeAll("\n  ]\n}\n");
    return out.toOwnedSlice();
}

/// Render the human-readable side-by-side table.
pub fn comparisonMarkdown(alloc: std.mem.Allocator, input: Input, comparison: Comparison) Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    const w = &out.writer;
    try w.print("# {s} thermal comparison\n\n{d} °C ambient, {s}, steady state. Positive Δ means Elmer is hotter.\n\n", .{
        input.design_name,
        comparison.ambient_c,
        coolingLabel(comparison.scenario),
    });
    try w.writeAll("| Result | Built-in | Elmer FEM | Δ |\n|---|---:|---:|---:|\n");
    try w.print("| Board maximum | {d:.2} °C | {d:.2} °C | {d:.2} °C |\n\n", .{
        comparison.board_max.builtin_c, comparison.board_max.elmer_c, comparison.board_max.delta_c,
    });
    try w.writeAll("| Part | Power | Built-in board | Elmer board | Δ board | Built-in junction | Elmer junction | Δ junction |\n|---|---:|---:|---:|---:|---:|---:|---:|\n");
    for (comparison.parts) |part| {
        try w.print("| {s} | {d:.3} W | {d:.2} °C | {d:.2} °C | {d:.2} °C | ", .{
            part.ref_des, part.watts, part.board.builtin_c, part.board.elmer_c, part.board.delta_c,
        });
        if (part.junction) |value| try w.print("{d:.2} °C", .{value.builtin_c}) else try w.writeAll("—");
        try w.writeAll(" | ");
        if (part.junction) |value| try w.print("{d:.2} °C", .{value.elmer_c}) else try w.writeAll("—");
        try w.writeAll(" | ");
        if (part.junction) |value| try w.print("{d:.2} °C", .{value.delta_c}) else try w.writeAll("—");
        try w.writeAll(" |\n");
    }
    try w.writeAll("\nJunction values use the same package/board-transfer uplift in both columns; the FEM delta therefore comes from the board-spreading solution. This is a numerical cross-check of the EDA screening assumptions, not independent material validation.\n");
    return out.toOwnedSlice();
}

// spec: export_elmer_thermal - an exported case contains a native hexahedral mesh, the selected natural or forced-air heat equation, normalized thermal-rule manifest, and portable run instructions
// spec: export_elmer_thermal - component watts are conserved as volumetric heat and each cell's two face losses equal the built-in cell-to-ambient conductance
// spec: export_elmer_thermal - cells clipped away by a rounded or custom outline are omitted from Elmer bodies and face boundaries
test "Elmer export emits a native hexahedral mesh and still-air case" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const conductivity = [_]f64{ 12.0, 24.0 };
    const face_h = [_]f64{ 10.0, 7.0 };
    const source = [_]f64{ 1000.0, 0.0 };
    const rises = try alloc.alloc(f32, 2);
    @memset(rises, 0);
    const input = Input{
        .design_name = "fixture",
        .ambient_c = 25,
        .sheet = thermal_field.defaultSheet(thermal_field.default_spreader_layers),
        .model = .{
            .shape = .{ .cols = 2, .rows = 1, .cell_mm = 1, .origin_x_mm = 0, .origin_y_mm = 0 },
            .thickness_m = 0.0016,
            .conductivity_w_mk = &conductivity,
            .top_face_h_w_m2k = &face_h,
            .bottom_face_h_w_m2k = &face_h,
            .heat_source_w_m3 = &source,
        },
        .solver_inputs = .{ .board = .{ .x_mm = 0, .y_mm = 0, .w_mm = 2, .h_mm = 1 } },
        .builtin = .{
            .scenario = .natural,
            .grid = .{ .cols = 2, .rows = 1, .cell_mm = 1, .origin_x_mm = 0, .origin_y_mm = 0, .rise_c = rises },
        },
    };
    const artifact = try build(alloc, input);
    try std.testing.expectEqualStrings("12 2 4\n2\n404 4\n808 2\n", artifact.mesh_header);
    try std.testing.expect(std.mem.indexOf(u8, artifact.mesh_elements, "1 1 808 1 2 5 4 7 8 11 10") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.sif, "External Temperature = 25") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact.sif, "Heat Source = 1000") != null);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, alloc, artifact.manifest, .{});

    // The bounding lattice may contain cells clipped away by a rounded or
    // custom outline. They are absent from the FEM bodies and face boundaries,
    // rather than silently restoring a rectangular slab around the PCB.
    const clipped_mask = [_]u8{ 1, 0 };
    var clipped_input = input;
    clipped_input.model.active = &clipped_mask;
    const clipped = try build(alloc, clipped_input);
    try std.testing.expectEqualStrings("12 1 2\n2\n404 2\n808 1\n", clipped.mesh_header);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, clipped.mesh_elements, " 808 "));

    var airflow_input = input;
    airflow_input.builtin.scenario = .airflow_1ms;
    const airflow = try build(alloc, airflow_input);
    try std.testing.expect(std.mem.indexOf(u8, airflow.manifest, "\"name\":\"airflow_1ms\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, airflow.manifest, "\"airSpeedMps\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, airflow.manifest, "\"faceFilmWm2K\":22") != null);
    try std.testing.expect(std.mem.indexOf(u8, airflow.readme, "1 m/s airflow") != null);

    const sink_parts = [_]thermal_field.PartInput{.{
        .ref_des = "U15",
        .watts = 1.2,
        .theta_jb = 5.4,
        .theta_jc = .{ .top = 15.3, .bottom = 0.9 },
        .mount = .{ .box = .{ .x_mm = 0, .y_mm = 0, .w_mm = 1, .h_mm = 1 }, .side = .top },
    }};
    const sink_rows = [_]thermal_field.PartField{.{
        .ref_des = "U15",
        .board_rise_c = 3,
        .tj_rise_c = 8,
        .junction_path = .package_top,
    }};
    var sink_input = input;
    sink_input.builtin.scenario = .heatsink;
    sink_input.builtin.parts = &sink_rows;
    sink_input.solver_inputs.parts = &sink_parts;
    sink_input.solver_inputs.cooling.heatsink = .{
        .ref_des = "U15",
        .side = .package_top,
        .physical_face = .top,
        .geometry = .{
            .width_mm = 20,
            .length_mm = 20,
            .base_mm = 2,
            .fin_height_mm = 10,
            .fin_thickness_mm = 1,
            .fin_gap_mm = 1.5,
        },
        .material = .aluminum_6061,
        .contact = .{ .x_mm = 1, .y_mm = 2, .w_mm = 20, .h_mm = 20 },
        .pad = .{ .thickness_mm = 0.5, .conductivity_w_mk = 6 },
    };
    const sunk = try build(alloc, sink_input);
    try std.testing.expect(std.mem.indexOf(u8, sunk.manifest, "\"contact\":\"package_top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sunk.manifest, "\"physicalBoardFace\":\"top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sunk.manifest, "\"material\":\"aluminum_6061\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sunk.manifest, "\"finThickness\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, sunk.manifest, "\"contactRectMm\":[1,2,20,20]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sunk.manifest, "\"thicknessMm\":0.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, sunk.readme, "20 x 20 mm") != null);

    var oversized = input;
    oversized.model.shape.cols = thermal_field.max_cells_axis + 1;
    try std.testing.expectError(error.InvalidModel, build(alloc, oversized));
}

// spec: export_elmer_thermal - VTU point coordinates restore Elmer's renumbered nodal temperatures to the native mesh node order
// spec: export_elmer_thermal - the comparison refuses a non-converged built-in field, a failed Elmer process, or a malformed/missing VTU result instead of publishing partial numbers
test "VTU parser reorders temperatures by Elmer point coordinates" {
    const xml =
        "<VTKFile><PointData><DataArray Name=\"temperature\">80 70 60 50 40 30 20 10</DataArray></PointData>" ++
        "<Points><DataArray>0.001 0.001 0.0016  0 0.001 0.0016  0.001 0 0.0016  0 0 0.0016 " ++
        "0.001 0.001 0  0 0.001 0  0.001 0 0  0 0 0</DataArray></Points></VTKFile>";
    const values = [_]f64{0};
    const model = thermal_field.Discretized{
        .shape = .{ .cols = 1, .rows = 1, .cell_mm = 1, .origin_x_mm = 0, .origin_y_mm = 0 },
        .thickness_m = 0.0016,
        .conductivity_w_mk = &values,
        .top_face_h_w_m2k = &values,
        .bottom_face_h_w_m2k = &values,
        .heat_source_w_m3 = &values,
    };
    const parsed = try parseVtu(std.testing.allocator, xml, model);
    defer std.testing.allocator.free(parsed.temperatures_by_node);
    try std.testing.expectEqualSlices(f64, &.{ 10, 20, 30, 40, 50, 60, 70, 80 }, parsed.temperatures_by_node);
    try std.testing.expectError(error.InvalidResult, parseVtu(std.testing.allocator, "<VTKFile/>", model));
}

// spec: export_elmer_thermal - a comparison reports board maximum and per-part board and junction temperatures in JSON and a side-by-side Markdown table
test "comparison reports board and junction temperatures side by side" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const coefficients = [_]f64{1};
    var rises = [_]f32{4};
    const parts = [_]thermal_field.PartInput{.{
        .ref_des = "U1",
        .watts = 2,
        .mount = .{ .box = .{ .x_mm = 0, .y_mm = 0, .w_mm = 1, .h_mm = 1 } },
    }};
    const builtin_parts = [_]thermal_field.PartField{.{
        .ref_des = "U1",
        .board_rise_c = 4,
        .tj_rise_c = 9,
    }};
    const input = Input{
        .design_name = "fixture",
        .sheet = thermal_field.defaultSheet(thermal_field.default_spreader_layers),
        .model = .{
            .shape = .{ .cols = 1, .rows = 1, .cell_mm = 1, .origin_x_mm = 0, .origin_y_mm = 0 },
            .thickness_m = 0.0016,
            .conductivity_w_mk = &coefficients,
            .top_face_h_w_m2k = &coefficients,
            .bottom_face_h_w_m2k = &coefficients,
            .heat_source_w_m3 = &coefficients,
        },
        .solver_inputs = .{
            .board = .{ .x_mm = 0, .y_mm = 0, .w_mm = 1, .h_mm = 1 },
            .parts = &parts,
        },
        .builtin = .{
            .scenario = .natural,
            .grid = .{ .cols = 1, .rows = 1, .cell_mm = 1, .origin_x_mm = 0, .origin_y_mm = 0, .rise_c = &rises },
            .parts = &builtin_parts,
            .hotspot = .{ .rise_c = 4 },
        },
    };
    var temperatures = [_]f64{ 30, 30, 30, 30, 30, 30, 30, 30 };
    const comparison = try compare(alloc, input, .{ .temperatures_by_node = &temperatures });
    try std.testing.expectEqual(thermal_field.Scenario.natural, comparison.scenario);
    try std.testing.expectEqual(@as(f64, 29), comparison.board_max.builtin_c);
    try std.testing.expectEqual(@as(f64, 30), comparison.board_max.elmer_c);
    try std.testing.expectEqual(@as(f64, 35), comparison.parts[0].junction.?.elmer_c);
    const json = try comparisonJson(alloc, comparison);
    const markdown = try comparisonMarkdown(alloc, input, comparison);
    _ = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    try std.testing.expect(std.mem.indexOf(u8, markdown, "| U1 | 2.000 W | 29.00 °C | 30.00 °C | 1.00 °C | 34.00 °C | 35.00 °C | 1.00 °C |") != null);
}
