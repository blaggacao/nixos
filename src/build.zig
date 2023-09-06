//! A replacement for `nixos-rebuild`.

const std = @import("std");
const fmt = std.fmt;
const fs = std.fs;
const mem = std.mem;
const meta = std.meta;
const os = std.os;

const Allocator = mem.Allocator;
const ArrayList = std.ArrayList;
const ArgIterator = std.process.ArgIterator;
const ComptimeStringMap = std.ComptimeStringMap;

const argparse = @import("argparse.zig");
const ArgParseError = argparse.ArgParseError;
const argIs = argparse.argIs;
const argIn = argparse.argIn;
const getNextArgs = argparse.getNextArgs;
const conflict = argparse.conflict;
const require = argparse.require;

const log = @import("log.zig");

const utils = @import("utils.zig");
const fileExistsAbsolute = utils.fileExistsAbsolute;
const runCmd = utils.runCmd;

pub const BuildArgs = struct {
    // Activate the built configuration
    activate: bool = false,
    // Make the built generation the default for next boot
    boot: bool = false,
    // Show what would be built or ran but do not actually run it
    dry: bool = false,
    // Build the NixOS system from the specified flake ref
    flake: ?[]const u8 = null,
    // Do not imply --flake if flake.nix exists in config location
    no_flake: bool = false,
    // (Re)install the bootloader on the device specified by the relevant configuration options
    install_bootloader: bool = false,
    // Symlink the output to a location (default: ./result, none on system activation)
    output: ?[]const u8 = null,
    // Name of the system profile to use
    profile_name: ?[]const u8 = null,
    // Activate the given specialisation (default: contents of /etc/NIXOS_SPECIALISATION)
    specialization: ?[]const u8 = null,
    // Upgrade the root user's 'nixos' channel
    upgrade_channels: bool = false,
    // Upgrade all of the root user's channels
    upgrade_all_channels: bool = false,
    // Build a script that starts a NixOS virtual machine with the given configuration
    vm: bool = false,
    // Same as --vm, but with a bootloader instead of booting into the kernel directly
    vm_with_bootloader: bool = false,

    /// All arguments passed through to `nix` invocations.
    build_args: ArrayList([]const u8),

    const Self = @This();

    const conflicts = .{
        // Cannot force usage of a flake and of no flakes
        .{ "flake", .{"no_flake"} },
        // --dry cannot be used with --output
        .{ "dry", .{"output"} },
        // VM options can only be set by themselves, and not with boot or activate
        .{ "vm", .{ "vm_with_bootloader", "activate", "boot" } },
    };

    const required = .{
        // Installing the bootloader requires an activation or boot entry generation
        .{ "install_bootloader", .{ "activate", "boot" } },
        // Specializations can only be used on activation
        .{ "specialization", .{"activate"} },
    };

    const usage =
        \\Usage:
        \\    nixos build [options]
        \\
        \\Options:
        \\    -a, --activate                 Activate the built configuration
        \\    -b, --boot                     Make the built generation the default for next boot
        \\    -d, --dry                      Show what would be built or ran but do not actually run it
        \\    -f, --flake <REF>              Build the NixOS system from the specified flake ref
        \\    --no-flake                     Do not imply --flake if flake.nix exists in config location
        \\    --install-bootloader           (Re)install the bootloader on the device specified by the
        \\                                   relevant configuration options
        \\    -o, --output <LOCATION>        Symlink the output to a location (default: ./result, none on
        \\                                   system activation)
        \\    -p, --profile-name <NAME>      Name of the system profile to use
        \\    -s, --specialisation <NAME>    Activate the given specialisation (default: contents of
        \\                                   /etc/NIXOS_SPECIALISATION if it exists)
        \\    --switch                       Alias for --activate --boot
        \\    -u, --upgrade                  Upgrade the root user's 'nixos' channel
        \\    --upgrade-all                  Upgrade all of the root user's channels
        \\    --vm                           Build a script that starts a NixOS virtual machine with the
        \\                                   given configuration
        \\    --vm-with-bootloader           Same as --vm, but with a bootloader instead of booting into
        \\                                   the kernel directly
        \\
        \\`nixos build` also forwards Nix options passed here to all Nix invocations.
        \\Check the manual for more details (we do a little trolling, there's no manpage).
        \\
    ;

    fn init(allocator: Allocator) Self {
        return BuildArgs{
            .build_args = ArrayList([]const u8).init(allocator),
        };
    }

    /// Parse arguments from the command line and construct a BuildArgs struct
    /// with the provided arguments. Caller owns a BuildArgs instance.
    pub fn parseArgs(allocator: Allocator, args: *ArgIterator) !BuildArgs {
        var result: BuildArgs = BuildArgs.init(allocator);
        errdefer result.deinit();

        var next_arg: ?[]const u8 = args.next();
        while (next_arg) |arg| {
            if (argIs(arg, "--activate", "-a")) {
                result.activate = true;
            } else if (argIs(arg, "--boot", "-b")) {
                result.boot = true;
            } else if (argIs(arg, "--dry", "-d")) {
                result.dry = true;
            } else if (argIs(arg, "--flake", "-f")) {
                const next = (try getNextArgs(args, arg, 1))[0];
                result.flake = next;
            } else if (argIs(arg, "--no-flake", null)) {
                result.no_flake = true;
            } else if (argIs(arg, "--help", "-h")) {
                log.print(usage, .{});
                return ArgParseError.HelpInvoked;
            } else if (argIs(arg, "--install-bootloader", null)) {
                result.install_bootloader = true;
            } else if (argIs(arg, "--output", "-o")) {
                const next = (try getNextArgs(args, arg, 1))[0];
                result.output = next;
            } else if (argIs(arg, "--profile-name", "-p")) {
                const next = (try getNextArgs(args, arg, 1))[0];
                result.profile_name = next;
            } else if (argIs(arg, "--switch", null)) {
                result.activate = true;
                result.boot = true;
            } else if (argIs(arg, "--specialisation", "-s")) {
                const next = (try getNextArgs(args, arg, 1))[0];
                result.specialization = next;
            } else if (argIs(arg, "--upgrade", "-u")) {
                result.upgrade_channels = true;
            } else if (argIs(arg, "--upgrade-all", null)) {
                result.upgrade_channels = true;
                result.upgrade_all_channels = true;
            } else if (argIn(arg, &.{ "--verbose", "-v", "-vv", "-vvv", "-vvvv", "-vvvvv" })) {
                verbose = true;
                try result.build_args.append(arg);
            } else if (argIs(arg, "--vm", null)) {
                result.vm = true;
            } else if (argIs(arg, "--vm-with-bootloader", null)) {
                result.vm_with_bootloader = true;
            } else if (argIn(arg, &.{ "--quiet", "--print-build-logs", "-L", "--no-build-output", "-Q", "--show-trace", "--keep-going", "-k", "--keep-failed", "-K", "--fallback", "--refresh", "--repair", "--impure", "--offline", "--no-net" })) {
                // Passthrough arguments to Nix with no additional arguments
                try result.build_args.append(arg);
            } else if (argIn(arg, &.{ "-I", "--max-jobs", "-j", "--cores", "--builders", "--log-format" })) {
                // Passthrough arguments to Nix with one additional argument
                const next = (try getNextArgs(args, arg, 1))[0];
                try result.build_args.append(arg);
                try result.build_args.append(next);
            } else if (argIs(arg, "--option", null)) {
                // --option takes two arguments, rather than 1
                const next_args = try getNextArgs(args, arg, 2);
                try result.build_args.appendSlice(&.{ arg, next_args[0], next_args[1] });
            } else {
                log.print(usage, .{});
                if (argparse.isFlag(arg)) {
                    log.err("unrecognised flag {s}", .{arg});
                } else {
                    log.err("argument {s} is not valid in this context", .{arg});
                }
                return ArgParseError.InvalidArgument;
            }

            next_arg = args.next();
        }

        try conflict(result, conflicts);
        try require(result, required);

        return result;
    }

    pub fn deinit(self: *Self) void {
        self.build_args.deinit();
    }
};

// Verbose output
// This is easier than to use a field in BuildArgs and pass it around.
var verbose: bool = false;

pub const BuildError = error{
    ConfigurationNotFound,
    CommandFailed,
    PermissionDenied,
    UnknownHostname,
    UnknownSpecialization,
    UnsupportedOs,
};

pub const BuildType = enum {
    System,
    SystemActivation,
    VM,
    VMWithBootloader,
};

/// NixOS configuration location inside a flake
const FlakeRef = struct {
    /// Path to flake that contains NixOS configuration
    path: []const u8,
    /// Hostname of configuration to build
    hostname: []const u8,
};

// Yes, I'm really this lazy. I don't want to use an allocator for this.
var hostname_buffer: [os.HOST_NAME_MAX]u8 = undefined;

/// Create a FlakeRef from a `flake#hostname` string. The hostname
/// can be inferred, but the `#` is mandatory.
fn getFlakeRef(arg: []const u8) !?FlakeRef {
    const index = mem.indexOf(u8, arg, "#") orelse return null;

    var path = arg[0..index];
    var hostname: []const u8 = undefined;

    if (index == (arg.len - 1)) {
        hostname = try os.gethostname(&hostname_buffer);
    } else {
        hostname = arg[(index + 1)..];
    }

    return FlakeRef{
        .path = path,
        .hostname = hostname,
    };
}

// Global exit status indicator for runCmd, so
// that the correct exit code from a failed command
// can be returned.
var exit_status: u8 = 0;

/// Iterate through all Nix channels and upgrade them if necessary
fn upgradeChannels(allocator: Allocator, all: bool) !void {
    var argv = ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.appendSlice(&.{ "nix-channel", "--update" });

    if (!all) {
        try argv.append("nixos");

        var dir = try fs.openIterableDirAbsolute("/nix/var/nix/profiles/per-user/root/channels", .{});
        defer dir.close();

        // Upgrade channels with ".update-on-nixos-rebuild"
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                const filename = try fmt.allocPrint(allocator, "/nix/var/nix/profiles/per-user/root/channels/{s}/.update-on-nixos-rebuild", .{entry.name});
                defer allocator.free(filename);
                if (fileExistsAbsolute(filename)) {
                    try argv.append(entry.name);
                }
            }
        }
    }

    if (verbose) log.cmd(argv.items);

    const result = runCmd(.{
        .allocator = allocator,
        .argv = argv.items,
    }) catch return BuildError.CommandFailed;

    if (result.status != 0) {
        return BuildError.CommandFailed;
    }
}

/// Make a temporary directory; this is basically just the `mktemp`
/// command but without actually invoking the `mktemp` command.
fn mkTmpDir(allocator: Allocator, name: []const u8) ![]const u8 {
    var random = std.rand.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    var rng = random.random();

    var i: usize = 0;
    var random_string: [8]u8 = undefined;
    while (i < 8) : (i += 1) {
        random_string[i] = rng.intRangeAtMost(u8, 'A', 'Z');
    }

    const tmpdir_location = os.getenv("TMPDIR") orelse "/tmp";
    const dirname = try fmt.allocPrint(
        allocator,
        "{s}/{s}.{s}",
        .{ tmpdir_location, name, random_string },
    );
    errdefer allocator.free(dirname);

    // TODO: replace to make consistent with
    try fs.makeDirAbsolute(dirname);

    return dirname;
}

/// Build a legacy-style NixOS configuration
fn nixBuild(
    allocator: Allocator,
    build_type: BuildType,
    options: struct {
        build_args: []const []const u8,
        result_dir: ?[]const u8 = null,
        dry: bool = false,
    },
) ![]const u8 {
    const attribute = switch (build_type) {
        .VM => "vm",
        .VMWithBootloader => "vmWithBootLoader",
        else => "system",
    };

    var argv = ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    // nix-build -A ${attribute} [-k] [--out-link <dir>] [${build_args}]
    try argv.appendSlice(&.{ "nix-build", "<nixpkgs/nixos>", "-A", attribute });

    // Mimic `nixos-rebuild` behavior of using -k option
    // for all commands except for switch and boot
    if (build_type != .SystemActivation) {
        try argv.append("-k");
    }

    if (options.result_dir) |dir| {
        try argv.append("--out-link");
        try argv.append(dir);
    }

    try argv.appendSlice(options.build_args);

    if (verbose) log.cmd(argv.items);

    // The stdout is the real output path, so no need to readlink anything
    const result = runCmd(.{
        .allocator = allocator,
        .argv = argv.items,
    }) catch return BuildError.CommandFailed;

    if (result.status != 0) {
        exit_status = 0;
        return BuildError.CommandFailed;
    }

    return result.stdout.?;
}

const flake_flags = &.{ "--extra-experimental-features", "nix-command flakes" };

/// Build a NixOS configuration located in a flake
fn nixBuildFlake(
    allocator: Allocator,
    build_type: BuildType,
    flake_ref: FlakeRef,
    options: struct {
        build_args: []const []const u8,
        result_dir: ?[]const u8 = null,
        dry: bool = false,
    },
) ![]const u8 {
    const attr_to_build = switch (build_type) {
        .VM => "vm",
        .VMWithBootloader => "vmWithBootLoader",
        else => "toplevel",
    };

    const attribute = try fmt.allocPrint(
        allocator,
        "{s}#nixosConfigurations.{s}.config.system.build.{s}",
        .{ flake_ref.path, flake_ref.hostname, attr_to_build },
    );
    defer allocator.free(attribute);

    var argv = ArrayList([]const u8).init(allocator);
    defer argv.deinit();

    // nix ${flake-flags} build ${attribute} [--out-link <dir>] [${build_args}]
    try argv.append("nix");
    try argv.appendSlice(flake_flags);
    try argv.appendSlice(&.{ "build", attribute });

    if (options.result_dir) |dir| {
        try argv.append("--out-link");
        try argv.append(dir);
    }

    if (options.dry) {
        try argv.append("--dry-run");
    }

    try argv.appendSlice(options.build_args);

    if (verbose) log.cmd(argv.items);

    var result = runCmd(.{
        .allocator = allocator,
        .argv = argv.items,
    }) catch return BuildError.CommandFailed;

    if (result.status != 0) {
        exit_status = result.status;
        return BuildError.CommandFailed;
    }

    if (result.stdout) |stdout| {
        allocator.free(stdout);
    }

    // No stdout output is emitted by nix build without --print-out-paths,
    // avoiding that option here to support Nix versions without it.
    // Reading the symlink suffices.
    var path_buf: [os.PATH_MAX]u8 = undefined;
    const path = try os.readlink(options.result_dir orelse "./result", &path_buf);
    return allocator.dupe(u8, path);
}

/// Set the target system's NixOS system profile to the newly built generation
/// to prepare for --activate or --boot
fn setNixEnvProfile(allocator: Allocator, profile: ?[]const u8, config_path: []const u8) !void {
    var profile_dir: []const u8 = undefined;

    if (profile) |name| {
        if (!mem.eql(u8, name, "system")) {
            // Create profile name directory if needed; this is grossly stupid
            // and requires root execution of `nixos`, because yeah.
            // How do I fix this?
            var base_dir = try fs.openDirAbsolute("/nix/var/nix/profiles", .{});
            defer base_dir.close();

            var subpath = try fmt.allocPrint(allocator, "system-profiles/{s}", .{name});
            allocator.free(subpath);

            profile_dir = try fmt.allocPrint(allocator, "/nix/var/nix/profiles/system-profiles/{s}", .{name});

            base_dir.makePath(subpath) catch |err| {
                log.err("unable to create profile directory {s}: {s}", .{ profile_dir, @errorName(err) });
                return BuildError.PermissionDenied;
            };
        }
    } else {
        // FIXME: Gross, I'm allocating this because I want to just use a single free.
        // Brain damage.
        profile_dir = try fmt.allocPrint(allocator, "/nix/var/nix/profiles/system", .{});
    }
    defer allocator.free(profile_dir);

    const argv = &.{ "nix-env", "-p", profile_dir, "--set", config_path };

    if (verbose) log.cmd(argv);

    const result = runCmd(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return BuildError.CommandFailed;

    if (result.status != 0) {
        exit_status = result.status;
        return BuildError.CommandFailed;
    }
}

// Find specialization name by looking at /etc/NIXOS_SPECIALISATION
fn findSpecialization(allocator: Allocator) !?[]const u8 {
    const file = fs.openFileAbsolute("/etc/NIXOS_SPECIALISATION", .{ .mode = .read_only }) catch return null;
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    var in_stream = buf_reader.reader();

    const specialization = try in_stream.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(usize));

    if (specialization != null and specialization.?.len == 0) {
        return null;
    }

    return specialization;
}

/// Run the switch-to-configuration.pl script
fn runSwitchToConfiguration(
    allocator: Allocator,
    location: []const u8,
    command: []const u8,
    options: struct { install_bootloader: bool = false },
) !void {
    var env_map = try std.process.getEnvMap(allocator);
    defer env_map.deinit();
    if (options.install_bootloader) {
        try env_map.put("NIXOS_INSTALL_BOOTLOADER", "1");
    }

    const argv = &.{ location, command };

    if (verbose) log.cmd(argv);

    const result = runCmd(.{
        .allocator = allocator,
        .argv = argv,
        .env_map = &env_map,
    }) catch return BuildError.CommandFailed;

    if (result.status != 0) {
        exit_status = result.status;
        return BuildError.CommandFailed;
    }
}

fn build(allocator: Allocator, arg_iter: *ArgIterator) !void {
    const args = try BuildArgs.parseArgs(allocator, arg_iter);

    if (!fileExistsAbsolute("/etc/NIXOS")) {
        log.err("the build command is currently unsupported on non-NixOS systems", .{});
        return BuildError.UnsupportedOs;
    }

    // TODO: check if user running is root?

    const build_type: BuildType = if (args.vm)
        .VM
    else if (args.vm_with_bootloader)
        .VMWithBootloader
    else if (args.activate or args.boot)
        .SystemActivation
    else
        .System;

    if (verbose) log.info("looking for configuration...", .{});
    // Find flake if unset, and parse it into its separate components
    var flake_ref: ?FlakeRef = null;
    if (args.flake) |flake| {
        flake_ref = getFlakeRef(flake) catch {
            log.err("unable to determine hostname", .{});
            return BuildError.UnknownHostname;
        };

        if (flake_ref == null) {
            log.err("hostname not provided in flake argument, cannot find configuration", .{});
            return BuildError.ConfigurationNotFound;
        }
    } else if (!args.no_flake) {
        // Check for existence of flake.nix in the NIXOS_CONFIG or /etc/nixos directory
        // and use that if found, and if --no-flake is not set
        const nixos_config = os.getenv("NIXOS_CONFIG") orelse "/etc/nixos";

        const nixos_config_is_flake = blk: {
            const filename = try fmt.allocPrint(allocator, "{s}/flake.nix", .{nixos_config});
            defer allocator.free(filename);
            break :blk fileExistsAbsolute(filename);
        };

        if (nixos_config_is_flake) {
            const dir = try fmt.allocPrint(allocator, "{s}#", .{nixos_config});
            flake_ref = try getFlakeRef(dir);
        }
    }

    if (flake_ref) |flake| {
        if (verbose) log.info("found flake configuration {s}#{s}", .{ flake.path, flake.hostname });
    } else {
        if (verbose) log.info("no flake configuration found, looking for legacy configuration", .{});
        // Verify legacy configuration exists, if needed (no need to store location,
        // because it is implicitly used by `nix-build "<nixpkgs/nixos>"`)
        const nixos_config = os.getenv("NIXOS_CONFIG");

        if (nixos_config) |dir| {
            const filename = try fmt.allocPrint(allocator, "{s}/default.nix", .{dir});
            defer allocator.free(filename);
            if (!fileExistsAbsolute(filename)) {
                log.err("no configuration found, expected {s} to exist", .{filename});
                return BuildError.ConfigurationNotFound;
            } else {
                if (verbose) log.info("found legacy configuration at {s}", .{filename});
            }
        } else {
            const nix_path = os.getenv("NIX_PATH") orelse "";
            var paths = mem.tokenize(u8, nix_path, ":");

            var configuration: ?[]const u8 = null;
            while (paths.next()) |path| {
                var kv = mem.tokenize(u8, path, "=");
                if (mem.eql(u8, kv.next() orelse "", "nixos-config")) {
                    configuration = kv.next();
                    break;
                }
            }

            if (configuration) |config| {
                if (verbose) log.info("found legacy configuration at {s}", .{config});
            } else {
                log.err("no configuration found, expected 'nixos-config' attribute to exist in NIX_PATH", .{});
                return BuildError.ConfigurationNotFound;
            }
        }
    }

    // Upgrade all channels (should this be skipped in flake mode?)
    if (args.upgrade_channels) {
        upgradeChannels(allocator, args.upgrade_all_channels) catch |err| {
            log.err("upgrading channels failed", .{});
            return err;
        };
    }

    // Create temporary directory for artifacts
    const tmp_dir = try mkTmpDir(allocator, "nixos-build");
    defer allocator.free(tmp_dir);
    defer {
        fs.deleteTreeAbsolute(tmp_dir) catch |err| {
            log.warn("unable to remove temporary directory {s}: {s}", .{ tmp_dir, @errorName(err) });
        };
    }

    // Build the system configuration
    log.print("building the system configuration...\n", .{});

    // Dry activation requires a real build, so --dry-run shouldn't be set
    // if --activate or --boot is set
    const dry_build = args.dry and !(args.activate or args.boot);

    // Only use this temporary directory for builds to be activated with
    const tmp_result_dir = try fmt.allocPrint(allocator, "{s}/result", .{tmp_dir});
    defer allocator.free(tmp_result_dir);

    const build_options = .{
        .build_args = args.build_args.items,
        .result_dir = if (args.output) |output|
            output
        else if (build_type == .SystemActivation)
            tmp_result_dir
        else
            null,
        .dry = dry_build,
    };

    // Location of the resulting NixOS generation
    var result: []const u8 = undefined;

    if (flake_ref) |flake| {
        result = nixBuildFlake(allocator, build_type, flake, build_options) catch |err| {
            log.err("failed to build the system configuration", .{});
            return err;
        };
    } else {
        result = nixBuild(allocator, build_type, build_options) catch |err| {
            log.err("failed to build the system configuration", .{});
            return err;
        };
    }

    // Yes, this is all just to mimic the behavior of nixos-rebuild to print
    // a message saying the VM can be ran with a command. Stupid, I know.
    if ((build_type == .VM or build_type == .VMWithBootloader) and !args.dry) {
        const dirname = try fmt.allocPrint(allocator, "{s}/bin", .{result});
        defer allocator.free(dirname);

        var dir = try fs.openIterableDirAbsolute(dirname, .{});
        defer dir.close();

        var filename: ?[]const u8 = null;

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (mem.startsWith(u8, entry.name, "run-") and mem.endsWith(u8, entry.name, "-vm")) {
                filename = entry.name;
                break;
            }
        }

        if (filename) |f| {
            log.print("Done. The virtual machine can be started by running {s}/{s}.\n", .{ dirname, f });
        } else unreachable; // Something catastrophic has happened, and the VM is in a different place.
    }

    if (build_type != .SystemActivation) {
        return;
    }

    // Set nix-env profile, if needed
    if (args.boot or args.activate and !args.dry) {
        setNixEnvProfile(allocator, args.profile_name, result) catch |err| {
            if (err == BuildError.CommandFailed) {
                log.err("failed to set system profile with nix-env", .{});
            }
            return err;
        };
    }

    // Run switch-to-configuration script, if needed. This will use the
    // specialization in /etc/NIXOS_SPECIALISATION, or it will default
    // to no specialization if no explicit specialization is provided.
    const specialization = args.specialization orelse try findSpecialization(allocator);

    const stc = if (specialization) |spec|
        try fmt.allocPrint(allocator, "{s}/specialisation/{s}/bin/switch-to-configuration", .{ result, spec })
    else
        try fmt.allocPrint(allocator, "{s}/bin/switch-to-configuration", .{result});
    defer allocator.free(stc);

    const stc_options = .{
        .install_bootloader = args.install_bootloader,
    };

    // Assert the spepcialization exists
    if (specialization) |spec| {
        if (!fileExistsAbsolute(stc)) {
            log.err("failed to find specialization {s}", .{spec});
            return BuildError.UnknownSpecialization;
        }
    }

    const stc_action = if (args.dry and args.activate)
        "dry-activate"
    else if (args.activate and args.boot)
        "switch"
    else if (args.boot)
        "boot"
    else if (args.activate)
        "test"
    else
        unreachable;

    // No need to print error message, the script will do that.
    try runSwitchToConfiguration(allocator, stc, stc_action, stc_options);
}

// Run build and provide the relevant exit code
pub fn buildMain(allocator: Allocator, args: *ArgIterator) u8 {
    build(allocator, args) catch |err| {
        switch (err) {
            ArgParseError.HelpInvoked => return 0,
            BuildError.ConfigurationNotFound => return 1,
            BuildError.CommandFailed => {
                return if (exit_status != 0)
                    exit_status
                else
                    1;
            },
            BuildError.PermissionDenied => return 13,
            BuildError.UnknownHostname => return 1,
            BuildError.UnsupportedOs => return 1,
            else => {
                log.err("{s}", .{@errorName(err)});
                return 1;
            },
        }
    };
    return 0;
}