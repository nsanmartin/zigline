const std = @import("std");
const zigline = @import("zigline.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    //stdout
    const stdout = std.io.getStdOut();
    const stdout_file = stdout.writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout_writer = bw.writer();
    //stdin
    const stdin = std.io.getStdIn(); //.reader();

    try stdout_writer.print("Zigline :) Exit with C-d\n", .{});
    try bw.flush(); // don't forget to flush!

    var readline = try zigline.Zigline.init(stdin, stdout, allocator);
    defer readline.deinit();
    while (true) {
        const read = try readline.readline();
        switch (read) {
            .line => |ln| {
                std.debug.print("{s}\n", .{ln});
                if (ln.len > 0) {
                    try readline.addHistory(ln);
                } else {
                    readline.alloc.free(ln);
                }
            },
            .no_line => |nol| switch (nol) {
                zigline.NoLine.CTRL_C => {
                    std.debug.print("^C\n", .{});
                },
                zigline.NoLine.CTRL_D => break,
            },
        }
    }

    for (readline.hist.items, 1..) |ln, i| {
        std.debug.print("line {d}: `{s}'\n", .{ i, ln });
    }
}
