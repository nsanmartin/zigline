const std = @import("std");
const os = @import("std").os;
const io = @import("std").io;

//const ENOTTY = 25; // TODO: search in std
const VMIN = 6; // TODO: where is this?
const VTIME = 5; // TODO: where is this?
//const TCSAFLUSH = 2; //
var rawmode: bool = false; // For atexit() function to check if restore is needed
var orig_termios: os.termios = undefined;

const KeyAction = enum(u8) {
    KEY_NULL = 0, // NULL
    CTRL_A = 1, // Ctrl+a
    CTRL_B = 2, // Ctrl-b
    CTRL_C = 3, // Ctrl-c
    CTRL_D = 4, // Ctrl-d
    CTRL_E = 5, // Ctrl-e
    CTRL_F = 6, // Ctrl-f
    CTRL_H = 8, // Ctrl-h
    TAB = 9, // Tab
    CTRL_K = 11, // Ctrl+k
    CTRL_L = 12, // Ctrl+l
    ENTER = 13, // Enter
    CTRL_N = 14, // Ctrl-n
    CTRL_P = 16, // Ctrl-p
    CTRL_T = 20, // Ctrl-t
    CTRL_U = 21, // Ctrl+u
    CTRL_W = 23, // Ctrl+w
    ESC = 27, // Escape
    BACKSPACE = 127, // Backspace
};

fn disableRawMode(fd: i32) !void {
    if (rawmode) {
        try os.tcsetattr(fd, os.TCSA.FLUSH, orig_termios);
        rawmode = false;
    }
}

fn enableRawMode(fd: i32) !void {
    var raw: os.termios = undefined;

    if (!os.isatty(os.STDIN_FILENO)) { //TODO: raise
        return;
    }

    orig_termios = try os.tcgetattr(fd);

    raw = orig_termios; // modify the original mode
    // input modes: no break, no CR to NL, no parity check, no strip char,
    // no start/stop output control.
    raw.iflag &= ~(os.linux.BRKINT | os.linux.ICRNL | os.linux.INPCK | os.linux.ISTRIP | os.linux.IXON);
    // output modes - disable post processing
    raw.oflag &= ~(os.linux.OPOST);
    // control modes - set 8 bit chars
    raw.cflag |= (os.linux.CS8);
    // local modes - choing off, canonical off, no extended functions, no
    // signal chars (^Z,^C)
    raw.lflag &= ~(os.linux.ECHO | os.linux.ICANON | os.linux.IEXTEN | os.linux.ISIG);
    // control chars - set return condition: min number of bytes and
    // timer. We want read to return every single byte, without timeout.
    raw.cc[VMIN] = 1;
    raw.cc[VTIME] = 0; // 1 byte, no timer

    // put terminal in raw mode after flushing
    try os.tcsetattr(fd, os.TCSA.FLUSH, raw);
    rawmode = true;
}

const Error = error{ Read, Write };

fn getChar(in: std.fs.File) !u8 {
    var buf: [1]u8 = undefined;
    const read = try in.reader().read(&buf);
    if (read < 1) {
        //try stdout.print("Run `zig build test` to run the tests.\n", .{});
        return Error.Read;
    }
    return buf[0];
}

fn getLine(in: std.fs.File, out: std.fs.File) !void {
    var bw = std.io.bufferedWriter(out.writer());
    const stdout_writer = bw.writer();
    var c: u8 = undefined;
    var buf = [_]u8{0};

    while (c != @intFromEnum(KeyAction.ENTER) and c != @intFromEnum(KeyAction.CTRL_D)) {
        c = try getChar(in);
        if (c == @intFromEnum(KeyAction.ENTER) and c == @intFromEnum(KeyAction.CTRL_D)) {
            return;
        }
        if (c == @intFromEnum(KeyAction.ESC)) {
            const s0 = try getChar(in);
            const s1 = try getChar(in);
            if (s0 == '[') {
                if (s1 >= '0' and s1 <= '9') { // Extended escape, read additional byte.
                    const s2 = try getChar(in);
                    if (s2 == '~') {
                        switch (s1) {
                            '3' => try stdout_writer.print("Del", .{}),
                            else => try stdout_writer.print("`Esc[N?~`", .{}),
                        }
                    }
                } else {
                    switch (s1) {
                        'A' => try stdout_writer.print("Up", .{}),
                        'B' => try stdout_writer.print("Down", .{}),
                        'C' => try stdout_writer.print("Right", .{}),
                        'D' => try stdout_writer.print("Left", .{}),
                        'H' => try stdout_writer.print("Home", .{}),
                        'F' => try stdout_writer.print("End", .{}),
                        else => try stdout_writer.print("`Esc[?`", .{}),
                    }
                }
            } else if (s0 == 'O') {
                switch (s1) {
                    'H' => try stdout_writer.print("Home", .{}),
                    'F' => try stdout_writer.print("End", .{}),
                    else => try stdout_writer.print("`EscO?`", .{}),
                }
            }
        } else {
            buf[0] = c;
            const written = try stdout_writer.write(&buf);
            if (written <= 0) {
                return Error.Write;
            }
        }
        try bw.flush(); // don't forget to flush!
    }
}

fn testMe0(in: std.fs.File) !void {
    var c: u8 = undefined;
    c = try in.reader().readByte();
    var buf: []u8 = undefined;
    buf[0] = c;
    //try out.writer().print("Char read: '{c}'\n", .{c});
}

fn testMe(in: std.fs.File, out: std.fs.File) !void {
    var c: u8 = undefined;
    c = try in.reader().readByte();
    var buf: []u8 = undefined;
    buf[0] = c;
    try out.writer().print("Char read: '{c}'\n", .{c});
}

pub fn main() !void {
    const stdout = std.io.getStdOut();
    const stdout_file = stdout.writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout_writer = bw.writer();
    const stdin = std.io.getStdIn(); //.reader();
    try enableRawMode(os.STDIN_FILENO);

    try stdout_writer.print("Line User Interface :) ", .{});
    try bw.flush(); // don't forget to flush!

    try getLine(stdin, stdout);
    //try testMe0(stdin);
    //try testMe(stdin, stdout);
    //var buf: [1]u8 = undefined;
    //const read = try stdin.read(&buf);
    //if (read < 1) {
    //    try stdout.print("Run `zig build test` to run the tests.\n", .{});
    //}
    //try stdout.print("char read: {c}", .{buf[0]});

    try bw.flush(); // don't forget to flush!
    try disableRawMode(os.STDIN_FILENO);
}

pub fn main_() !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();
    const stdin = std.io.getStdIn().reader();
    try enableRawMode(os.STDIN_FILENO);

    try stdout.print("Line User Interface :) ", .{});
    try bw.flush(); // don't forget to flush!

    var buf: [1]u8 = undefined;
    const read = try stdin.read(&buf);
    if (read < 1) {
        try stdout.print("Run `zig build test` to run the tests.\n", .{});
    }
    try stdout.print("char read: {c}", .{buf[0]});

    try bw.flush(); // don't forget to flush!
    try disableRawMode(os.STDIN_FILENO);
}
