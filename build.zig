const std = @import("std");

const ModuleImport = std.Build.Module.Import;
const CompletionTarget = struct {
    shell: []const u8,
    filename: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(bool, "profile", "Enable compile profiling (comptime, zero-cost when disabled)") orelse false;
    const version = readPackageVersion();

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "profile", profile);
    build_opts.addOption([]const u8, "version", version);
    build_opts.addOption([]const u8, "_id", "zsass");
    const zsass_options_module = build_opts.createModule();

    const compiler_module = b.addModule("compiler", .{
        .root_source_file = b.path("src/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zsass_options", .module = zsass_options_module },
        },
    });
    const compiler_imports = &[_]ModuleImport{
        .{ .name = "compiler", .module = compiler_module },
    };
    const spec_runner_imports = compiler_imports;

    // Main executable (VM entrypoint)
    const exe = addExecutable(
        b,
        "zsass",
        b.path("src/main.zig"),
        target,
        optimize,
        zsass_options_module,
        &.{},
        true,
    );
    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run zsass compiler");
    const run_cmd = addRunArtifact(b, exe, &.{}, true);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // CLI sample step: compiles the repo's sample.scss into zig-out/examples/
    const cli_sample_css = b.pathJoin(&.{ "zig-out", "examples", "sample.css" });
    _ = addRunStep(
        b,
        "cli-sample",
        "Build zsass and compile examples/sample.scss to zig-out/examples/sample.css",
        exe,
        &.{ "examples/sample.scss", cli_sample_css, "--source-map" },
        true,
    );

    // Embedding API examples (referenced from README and docs/api.md).
    const api_example_exe = addExecutable(
        b,
        "embed_basic",
        b.path("examples/embed_basic.zig"),
        target,
        optimize,
        zsass_options_module,
        compiler_imports,
        true,
    );
    const api_example_step = b.step(
        "api-example",
        "Build and run examples/embed_basic.zig (in-memory compileSourceToCssWithSourceMap demo)",
    );
    const run_api_example = b.addRunArtifact(api_example_exe);
    api_example_step.dependOn(&run_api_example.step);

    const api_file_example_exe = addExecutable(
        b,
        "embed_file",
        b.path("examples/embed_file.zig"),
        target,
        optimize,
        zsass_options_module,
        compiler_imports,
        true,
    );
    const api_file_example_step = b.step(
        "api-file-example",
        "Build and run examples/embed_file.zig (file-based compile demo with source map)",
    );
    const run_api_file_example = b.addRunArtifact(api_file_example_exe);
    api_file_example_step.dependOn(&run_api_file_example.step);

    const api_files_example_exe = addExecutable(
        b,
        "embed_files",
        b.path("examples/embed_files.zig"),
        target,
        optimize,
        zsass_options_module,
        compiler_imports,
        true,
    );
    const api_files_example_step = b.step(
        "api-files-example",
        "Build and run examples/embed_files.zig (parallel batch compile + compressed output)",
    );
    const run_api_files_example = b.addRunArtifact(api_files_example_exe);
    api_files_example_step.dependOn(&run_api_files_example.step);

    // api-smoke: chains the in-memory and file-based examples for a single regression check.
    const api_smoke_step = b.step(
        "api-smoke",
        "Run all embedding examples back-to-back as a public-API regression check",
    );
    const run_api_example_smoke = b.addRunArtifact(api_example_exe);
    const run_api_file_example_smoke = b.addRunArtifact(api_file_example_exe);
    run_api_file_example_smoke.step.dependOn(&run_api_example_smoke.step);
    const run_api_files_example_smoke = b.addRunArtifact(api_files_example_exe);
    run_api_files_example_smoke.step.dependOn(&run_api_file_example_smoke.step);
    api_smoke_step.dependOn(&run_api_files_example_smoke.step);

    // quickstart: CLI smoke (--version + --info) followed by the API smoke chain.
    const quickstart_step = b.step(
        "quickstart",
        "CLI smoke (--version + --info) followed by all embedding examples",
    );
    const run_cli_version = addRunArtifact(b, exe, &.{"--version"}, true);
    const run_cli_info = addRunArtifact(b, exe, &.{"--info"}, true);
    run_cli_info.step.dependOn(&run_cli_version.step);
    const run_api_example_quick = b.addRunArtifact(api_example_exe);
    run_api_example_quick.step.dependOn(&run_cli_info.step);
    const run_api_file_example_quick = b.addRunArtifact(api_file_example_exe);
    run_api_file_example_quick.step.dependOn(&run_api_example_quick.step);
    const run_api_files_example_quick = b.addRunArtifact(api_files_example_exe);
    run_api_files_example_quick.step.dependOn(&run_api_file_example_quick.step);
    quickstart_step.dependOn(&run_api_files_example_quick.step);

    const installed_zsass = b.getInstallPath(.bin, "zsass");

    const realworld_step = b.step(
        "realworld",
        "Run external real-world suite checks (defaults to all suites under ../zsass-realworld-fixtures; uses --jobs 4 for stability); pass runner args after `--` (for help: `zig build realworld -- --help`)",
    );
    const realworld = b.addSystemCommand(&[_][]const u8{
        "scripts/realworld_suite.sh",
        "--zsass-bin",
        installed_zsass,
        "--jobs",
        "4",
    });
    realworld.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        realworld.addArgs(args);
    }
    realworld_step.dependOn(&realworld.step);

    // Shell completions: generate ready-to-source files under zig-out/completions
    const completions_dir = b.pathJoin(&.{ "zig-out", "completions" });
    const completions_targets = [_]CompletionTarget{
        .{ .shell = "bash", .filename = "zsass.bash" },
        .{ .shell = "zsh", .filename = "zsass.zsh" },
        .{ .shell = "fish", .filename = "zsass.fish" },
    };

    const completions_all_step = b.step("completions", "Generate bash/zsh/fish completions under zig-out/completions");
    for (completions_targets) |target_info| {
        completions_all_step.dependOn(addCompletionStep(b, completions_dir, target_info));
    }

    //Unit test step -- runs only unit tests (fast)
    const unit_test_step = b.step("unit-test", "Run unit tests (without sass-spec)");

    // Tests for main (imports all modules)
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    unit_test_step.dependOn(&run_exe_tests.step);

    //Test step -- runs unit tests + sass-spec integration tests
    const test_step = b.step("test", "Run unit tests and sass-spec integration tests");
    test_step.dependOn(&run_exe_tests.step);

    // Spec test step - sass-spec integration tests (also available standalone)
    const spec_step = b.step("spec", "Run sass-spec tests");

    //Spec runner as executable -- import legacy compiler + vm api engines
    const spec_exe = addExecutable(
        b,
        "spec_runner",
        b.path("tests/spec_runner.zig"),
        target,
        optimize,
        zsass_options_module,
        spec_runner_imports,
        true,
    );
    // Default `zig build install` installs only zsass; use `zig build spec-runner` for zig-out/bin/spec_runner.
    const install_spec_runner_artifact = b.addInstallArtifact(spec_exe, .{});
    const spec_runner_step = b.step("spec-runner", "Build and install spec_runner to PREFIX/bin");
    spec_runner_step.dependOn(&install_spec_runner_artifact.step);

    const run_spec = addRunArtifact(b, spec_exe, &.{}, false);
    if (b.args) |args| {
        run_spec.addArgs(args);
    }
    spec_step.dependOn(&run_spec.step);

    // Include sass-spec in `zig build test` (quiet mode, runs after unit tests)
    const run_spec_in_test = addRunArtifact(b, spec_exe, &.{"--quiet"}, false);
    run_spec_in_test.step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_spec_in_test.step);

    // Spec runner unit tests (HRX parser tests). `tests/spec_runner.zig`
    // forks via `std.c.fork` so it cannot even *compile* on Windows --
    // only attach the spec-runner test artifact when the host target
    // supports the POSIX subset it uses. Windows / non-POSIX hosts still
    // get the full src/ unit-test pass; they just skip the HRX-parser
    // sub-tests that live alongside the runner.
    if (target.result.os.tag != .windows) {
        const spec_tests = b.addTest(.{
            .root_module = createRootModule(
                b,
                b.path("tests/spec_runner.zig"),
                target,
                optimize,
                zsass_options_module,
                compiler_imports,
                true,
            ),
        });
        const run_spec_tests = b.addRunArtifact(spec_tests);
        unit_test_step.dependOn(&run_spec_tests.step);
        test_step.dependOn(&run_spec_tests.step);
    }
}

fn readPackageVersion() []const u8 {
    const zon = @embedFile("build.zig.zon");

    var lines = std.mem.splitScalar(u8, zon, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, ".version ")) continue;
        const first_quote = std.mem.indexOfScalar(u8, trimmed, '"') orelse break;
        const rest = trimmed[first_quote + 1 ..];
        const second_quote = std.mem.indexOfScalar(u8, rest, '"') orelse break;
        return rest[0..second_quote];
    }
    std.debug.panic("failed to find .version in build.zig.zon", .{});
}

fn addExecutable(
    b: *std.Build,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zsass_options_module: *std.Build.Module,
    imports: []const ModuleImport,
    link_libc: bool,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = createRootModule(
            b,
            root_source_file,
            target,
            optimize,
            zsass_options_module,
            imports,
            link_libc,
        ),
    });
}

fn createRootModule(
    b: *std.Build,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zsass_options_module: *std.Build.Module,
    imports: []const ModuleImport,
    link_libc: bool,
) *std.Build.Module {
    const all_imports = b.allocator.alloc(ModuleImport, imports.len + 1) catch @panic("OOM");
    all_imports[0] = .{ .name = "zsass_options", .module = zsass_options_module };
    @memcpy(all_imports[1..], imports);

    return b.createModule(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
        .imports = all_imports,
        .link_libc = link_libc,
    });
}

fn addRunArtifact(
    b: *std.Build,
    artifact: *std.Build.Step.Compile,
    args: []const []const u8,
    depend_on_install: bool,
) *std.Build.Step.Run {
    const run = b.addRunArtifact(artifact);
    if (args.len > 0) {
        run.addArgs(args);
    }
    if (depend_on_install) {
        run.step.dependOn(b.getInstallStep());
    }
    return run;
}

fn addRunStep(
    b: *std.Build,
    step_name: []const u8,
    step_desc: []const u8,
    artifact: *std.Build.Step.Compile,
    args: []const []const u8,
    depend_on_install: bool,
) *std.Build.Step {
    const step = b.step(step_name, step_desc);
    const run = addRunArtifact(b, artifact, args, depend_on_install);
    step.dependOn(&run.step);
    return step;
}

fn addCompletionStep(
    b: *std.Build,
    completions_dir: []const u8,
    target_info: CompletionTarget,
) *std.Build.Step {
    const output_path = b.pathJoin(&.{ completions_dir, target_info.filename });
    const step_name = b.fmt("completions-{s}", .{target_info.shell});
    const step_desc = b.fmt("Generate {s} completions into {s}", .{ target_info.shell, output_path });
    const completion_step = b.step(step_name, step_desc);
    const completion_cmd = b.addSystemCommand(&[_][]const u8{
        "scripts/install_completions.sh",
        "--shell",
        target_info.shell,
        "--output",
        output_path,
    });
    completion_cmd.step.dependOn(b.getInstallStep());
    completion_step.dependOn(&completion_cmd.step);
    return completion_step;
}
