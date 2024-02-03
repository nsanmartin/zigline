const std = @import("std");
const os = @import("std").os;
const io = @import("std").io;

//const ENOTTY = 25; // TODO: search in std
const VMIN = 6; // TODO: where is this?
const VTIME = 5; // TODO: where is this?
//const TCSAFLUSH = 2; //
var rawmode: bool = false; // For atexit() function to check if restore is needed
var orig_termios: os.termios = undefined;

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

pub fn main() !void {
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
