const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const ArgIterator = std.process.ArgIterator;

const build = @import("build.zig");
const enter = @import("enter.zig");

const log = @import("log.zig");

const argparse = @import("argparse.zig");
const argError = argparse.argError;
const App = argparse.App;
const ArgParseError = argparse.ArgParseError;
const Command = argparse.Command;

const MainArgs = struct {
    subcommand: ?Subcommand = null,

    const Subcommand = enum {
        build,
        enter,
    };

    const usage =
        \\Usage:
        \\    nixos <command> [command options]
        \\
        \\Commands:
        \\    build    Build a NixOS configuration
        \\    enter    Chroot into a NixOS installation
        \\
        \\Options:
        \\    -h, --help    Show this help menu
        \\
        \\For more information about a command, add --help after.
        \\
    ;

    pub fn parseArgs(args: *ArgIterator) !MainArgs {
        var result: MainArgs = MainArgs{};

        const next_arg = args.next();

        if (next_arg == null) {
            argError("no subcommand specified", .{});
            return ArgParseError.MissingRequiredArgument;
        }

        const arg = next_arg.?;

        if (argparse.argIs(arg, "--help", "-h")) {
            log.print(usage, .{});
            return ArgParseError.HelpInvoked;
        }

        if (mem.eql(u8, arg, "build")) {
            result.subcommand = .build;
        } else if (mem.eql(u8, arg, "enter")) {
            result.subcommand = .enter;
        } else {
            if (argparse.isFlag(arg)) {
                argError("unrecognised flag '{s}'", .{arg});
                return ArgParseError.InvalidArgument;
            } else {
                argError("unknown subcommand '{s}'", .{arg});
                return ArgParseError.InvalidSubcommand;
            }
        }

        return result;
    }
};

pub fn main() !u8 {
    var arena_allocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const allocator = arena_allocator.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip executable name
    _ = args.next();

    const mainArgs = MainArgs.parseArgs(&args) catch |err| {
        switch (err) {
            ArgParseError.HelpInvoked => return 0,
            else => return 2,
        }
    };

    const status = switch (mainArgs.subcommand.?) {
        .build => build.buildMain(allocator, &args),
        .enter => enter.enterMain(allocator, &args),
    };

    return status;
}
